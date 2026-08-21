/**
 * Tests for `DispositionOfferFormService` — the Log Offer dialog's read (2026-08-21).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT THIS CLASS IS ACTUALLY DEFENDING
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 1. THE BROKER SOURCE IS PER RECORD TYPE, AND THE TWO SOURCES ARE DIFFERENT OBJECTS. On-market
 *    it is the SELECTED `BOV_Submission__c`'s `Broker__c`; off-market it is
 *    `Disposition__c.Broker__c`. Getting this backwards does not throw — it silently attributes
 *    every off-market offer to a BOV broker who was never appointed, or leaves every on-market
 *    offer brokerless. Both directions are asserted, and the CROSS-CONTAMINATION is asserted as
 *    absence (an off-market sale that ALSO has a Selected BOV row must still read the parent).
 * 2. `Selected_Broker__c` IS NEVER PARSED. It is a display string that reads "Firm" on one path
 *    and "Person - Firm" on the other, and its own field metadata says NO CONSUMER MAY PARSE IT.
 *    A test below gives it a value that would produce a WRONG answer if anyone ever did.
 * 3. THE BUYER LIST IS DE-DUPLICATED BY CONTACT ID. The selector deliberately does not (SOQL has
 *    no SELECT DISTINCT), so this is the only place that collapses two NDAs for one party — and
 *    a duplicate `value` in a `lightning-combobox` renders a dead, unselectable menu item.
 * 4. THE QUERY BUDGET IS A CEILING, NOT A DESCRIPTION. 3 SOQL on-market, 2 off-market, 1 for a
 *    null/invalid parent. A fourth query added later is invisible on a single-record screen.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE DOES NOT APPLY HERE, AND THE REASON
 *   IS RECORDED SO REVIEW DOES NOT DEMAND IT.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `getFormContext` takes a SINGLE `Id`. It is invoked exactly once per modal open by a `@wire`;
 * there is no trigger, no batch, no queueable and no collection parameter. That is the rule's own
 * "structurally single-record-per-transaction" exemption, and it is STRUCTURAL rather than
 * convenient: there is no loop over records that a 251st row would force a second pass through,
 * so a 251-record test would exercise no additional code path while risking unrelated governor
 * limits — the exact anti-pattern the exemption exists to prevent.
 * 🔴 IT IS NOT A RELAXATION OF "no SOQL/DML in loops", WHICH IS HONOURED IN FULL AND IS TESTED:
 * `budget_*` below prove the query count is CONSTANT in the number of buyers, which is the part
 * that would actually break. ⚠ IF A CALLER EVER PASSES A COLLECTION, THIS EXEMPTION LAPSES.
 *
 * ⚠ `@TestSetup` builds Property -> Property_Asset only. Every test creates its OWN Disposition,
 * because the record type is the variable under test in half of them and a shared on-market
 * scaffold row would quietly make the off-market cases untestable.
 */
@isTest
private class DispositionOfferFormServiceTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c onMarket() {
        return TestDataFactory.createDisposition(
            assetId(),
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
    }

    private static Disposition__c offMarket(Id brokerContactId) {
        Disposition__c disposition = TestDataFactory.createDisposition(
            assetId(),
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            false
        );
        disposition.Broker__c = brokerContactId;
        insert disposition;
        return disposition;
    }

    /** A signed, buyer-role NDA naming a Contact — the only shape the picker accepts. */
    private static NDA__c signedBuyerNda(Id dispositionId, Id buyerContactId) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId, false);
        nda.Status__c = 'Signed';
        nda.Buyer__c = buyerContactId;
        insert nda;
        return nda;
    }

    /** Promotes one of a disposition's BOV submissions to Selected and returns its broker Id. */
    private static Id appointBovBroker(Id dispositionId) {
        BOV_Submission__c submission =
            TestDataFactory.createBovSubmission(dispositionId, true);
        submission.Submission_Status__c = 'Selected';
        update submission;
        return submission.Broker__c;
    }

    private static Set<Id> buyerIdsOf(DispositionOfferFormService.OfferFormContext context) {
        Set<Id> ids = new Set<Id>();
        for (DispositionOfferFormService.BuyerOption option : context.buyers) {
            ids.add((Id) option.value);
        }
        return ids;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BROKER — two record types, two sources, and no cross-contamination
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void onMarket_resolvesTheBrokerFromTheSelectedBovSubmission() {
        Disposition__c disposition = onMarket();
        Id expectedBroker = appointBovBroker(disposition.Id);
        Contact broker = [SELECT Id, Name FROM Contact WHERE Id = :expectedBroker LIMIT 1];

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        Assert.areEqual(true, context.isOnMarket, 'The On_Market record type');
        Assert.areEqual(expectedBroker, context.brokerId,
            'On-market, the broker is the SELECTED BOV submission\'s Broker__c');
        Assert.areEqual(broker.Name, context.brokerName,
            'The name is displayed read-only beside the picker');
        Assert.areEqual(DispositionOfferFormService.SOURCE_ON_MARKET, context.brokerSource,
            'The source line tells the analyst WHY that name is there');
    }

    @isTest
    static void offMarket_resolvesTheBrokerFromTheDispositionLookup() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);
        Contact expected = [SELECT Id, Name FROM Contact WHERE Id = :broker.Id LIMIT 1];

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        Assert.areEqual(false, context.isOnMarket, 'The Off_Market record type');
        Assert.areEqual(broker.Id, context.brokerId,
            'Off-market, the broker is Disposition__c.Broker__c — read straight off the parent');
        Assert.areEqual(expected.Name, context.brokerName, 'With its display name');
        Assert.areEqual(DispositionOfferFormService.SOURCE_OFF_MARKET, context.brokerSource,
            'The off-market source wording, which points at a different screen');
    }

    @isTest
    static void offMarket_ignoresASelectedBovSubmissionEvenWhenOneExists() {
        Contact parentBroker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(parentBroker.Id);
        Id bovBroker = appointBovBroker(disposition.Id);

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        // 🔴 CROSS-CONTAMINATION, ASSERTED AS ABSENCE. A record-type branch that fell through —
        // or read both sources and preferred the wrong one — would attribute this off-market
        // offer to a BOV broker who was never appointed to it. It fails silently: both values
        // are real Contact Ids and both render perfectly well in the dialog.
        Assert.areEqual(parentBroker.Id, context.brokerId,
            'Off-market must read the PARENT lookup, never the BOV row');
        Assert.areNotEqual(bovBroker, context.brokerId,
            'The Selected BOV submission is not the off-market source');
    }

    @isTest
    static void onMarket_noSelectedSubmission_leavesTheBrokerEmptyButStillLoads() {
        Disposition__c disposition = onMarket();
        // Every factory submission defaults to Backup — the state before the appointment is
        // approved, which is exactly when an early offer might be logged.
        TestDataFactory.createBovSubmissions(2, disposition.Id, true);
        Contact buyer = TestDataFactory.createContact(null, true);
        signedBuyerNda(disposition.Id, buyer.Id);

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        // 🔴 A NULL BROKER IS AN ACCEPTED OUTCOME, NOT A FAILURE. Nothing backfills it later —
        // that was accepted in the design rather than solved — and the dialog must still work.
        Assert.isNull(context.brokerId, 'No Selected submission means no broker yet');
        Assert.areEqual('', context.brokerName,
            'NEVER null across the @AuraEnabled boundary — an undefined renders as "undefined"');
        Assert.areEqual(1, context.buyers.size(), 'The buyer picker still loads');
    }

    /**
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE "SELECTED ROW WITH A NULL BROKER" STATE CANNOT BE BUILT, AND THIS TEST ASSERTS THE
     *    PREMISE INSTEAD OF PRETENDING IT CAN.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * The service's `if (submission.Broker__c != null)` skip is a defensive branch, and the first
     * version of this file tried to exercise it by nulling `Broker__c` on a Selected submission.
     * MEASURED 2026-08-21 — that DML is refused outright:
     *
     *   FIELD_CUSTOM_VALIDATION_EXCEPTION, "Choose the Broker Contact who submitted this BOV.
     *   A submission with no broker cannot be compared or appointed." : [Broker__c]
     *
     * `Broker_Required_On_Submission` is ACTIVE and has no ISNEW/ISCHANGED guard, so it refuses
     * every save — the state is unreachable through any supported write path.
     *
     * ⚠ THAT DOES **NOT** MAKE THE SERVICE'S BRANCH DEAD CODE, and it must not be deleted on that
     * argument. Two live routes still produce it: a submission created BEFORE that rule was
     * activated (the rule cannot retroactively repair rows), and a Contact deleted after the fact
     * — `Broker__c` uses `SetNull`, so the platform nulls the lookup with no validation rule in
     * the way. Both leave a Selected row with no broker, and the skip is what stops the dialog
     * accepting it and masking a real row further down the list.
     *
     * ⚠ THE PREMISE IS ASSERTED RATHER THAN ASSUMED because if that rule is ever relaxed, the
     * unbuildable fixture becomes buildable and a proper positive test SHOULD be written here.
     * This test going red is the signal to write it.
     */
    @isTest
    static void aSelectedSubmissionCannotBeStrippedOfItsBroker_soTheSkipStaysDefensive() {
        Disposition__c disposition = onMarket();
        BOV_Submission__c submission =
            TestDataFactory.createBovSubmission(disposition.Id, true);
        submission.Submission_Status__c = 'Selected';
        submission.Broker__c = null;

        Test.startTest();
        Boolean refused = false;
        try {
            update submission;
        } catch (DmlException e) {
            refused = true;
            Assert.isTrue(
                e.getMessage().contains('Broker'),
                'The refusal must be the broker rule, not some unrelated failure: '
                    + e.getMessage()
            );
        }
        Test.stopTest();

        Assert.isTrue(refused,
            'Broker_Required_On_Submission must still refuse a Selected row with no broker. If '
                + 'this now SAVES, the rule was relaxed — write the real positive test for the '
                + 'service\'s null-broker skip instead of deleting this one.');
    }

    @isTest
    static void selectedBrokerTextIsNeverParsed_evenWhenItWouldGiveTheWrongAnswer() {
        Contact parentBroker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(parentBroker.Id);
        // `Selected_Broker__c` is stamped by DispositionBrokerStampService from Broker__c, so it
        // already agrees. Overwrite it with a DIFFERENT name: if anything ever parsed it, the
        // assertion below would return this string instead of the real Contact's.
        disposition.Selected_Broker__c = 'Someone Else - Wrong Firm';
        update disposition;
        Contact expected = [SELECT Id, Name FROM Contact WHERE Id = :parentBroker.Id LIMIT 1];

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        // 🔴 THE STANDING RULE: "NO CONSUMER MAY PARSE `Selected_Broker__c`." It reads "Firm" on
        // on-market rows and "Person - Firm" on off-market ones, so a parser works on whichever
        // path its author tested and fails silently on the other. It is the obvious shortcut here
        // (one field, both paths, one fewer query) and this test is what makes taking it fail.
        Assert.areEqual(expected.Name, context.brokerName,
            'The name comes from the Contact traversal, never from the display string');
        Assert.areNotEqual('Someone Else - Wrong Firm', context.brokerName,
            'Selected_Broker__c must not reach this DTO by any route');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BUYERS — the picker's contents
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void buyers_areReturnedAsContactIdKeyedOptionsWithNames() {
        Disposition__c disposition = onMarket();
        Contact buyer = TestDataFactory.createContact(null, true);
        signedBuyerNda(disposition.Id, buyer.Id);
        Contact expected = [SELECT Id, Name FROM Contact WHERE Id = :buyer.Id LIMIT 1];

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        Assert.areEqual(1, context.buyers.size(), 'One qualifying buyer');
        // 🔴 THE OPTION VALUE IS THE **CONTACT** ID, NOT THE NDA ID. Returning the NDA Id would
        // compile, render identically, save without error, and silently populate
        // `Disposition_Offer__c.Buyer__c` with a row that is not a Contact — caught by nothing
        // until c/dispositionBuyerTimeline showed blanks for every buyer.
        Assert.areEqual((String) expected.Id, context.buyers[0].value,
            'The value must be the buyer CONTACT Id');
        Assert.areEqual(expected.Name, context.buyers[0].label, 'Labelled with the Contact name');
    }

    @isTest
    static void buyers_areDeDuplicatedWhenOnePartyHasTwoNdas() {
        Disposition__c disposition = onMarket();
        Contact buyer = TestDataFactory.createContact(null, true);
        // An NDA re-issued rather than amended is the ordinary way to reach this.
        signedBuyerNda(disposition.Id, buyer.Id);
        signedBuyerNda(disposition.Id, buyer.Id);

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        // 🔴 SOQL HAS NO `SELECT DISTINCT`, so the selector returns both rows on purpose (pinned
        // in NdaSelectorTest) and THIS is the only place that collapses them. A duplicate `value`
        // in a lightning-combobox renders a second option that can never be selected — a dead
        // menu item, which reads to the user as a broken control rather than as a data issue.
        Assert.areEqual(1, context.buyers.size(),
            'Two NDAs naming one Contact produce ONE option');
        Assert.areEqual((String) buyer.Id, context.buyers[0].value, 'Keyed on the Contact');
    }

    @isTest
    static void buyers_excludeTheIntroducingBrokerAndUnsignedParties() {
        Disposition__c disposition = onMarket();
        Contact buyer = TestDataFactory.createContact(null, true);
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Contact pending = TestDataFactory.createContact(null, true);
        signedBuyerNda(disposition.Id, buyer.Id);

        NDA__c brokerNda = TestDataFactory.createDispositionNda(disposition.Id, false);
        brokerNda.Party_Role__c = 'Introducing Broker';
        brokerNda.Status__c = 'Signed';
        brokerNda.Buyer__c = broker.Id;
        insert brokerNda;

        NDA__c unsigned = TestDataFactory.createDispositionNda(disposition.Id, false);
        unsigned.Buyer__c = pending.Id;
        insert unsigned;

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        Set<Id> offered = buyerIdsOf(context);
        Assert.areEqual(1, context.buyers.size(), 'Only the signed BUYER-role party');
        Assert.isTrue(offered.contains(buyer.Id), 'The buyer is offered');
        // Asserted here as well as in NdaSelectorTest deliberately: the predicate lives in the
        // selector, but this is the layer whose OUTPUT a human clicks on.
        Assert.isFalse(offered.contains(broker.Id),
            'The introducing broker must never be offered as a buyer');
        Assert.isFalse(offered.contains(pending.Id), 'An unsigned party is not selectable');
    }

    @isTest
    static void buyers_emptyIsAFirstClassAnswer_notAnError() {
        Disposition__c disposition = onMarket();
        appointBovBroker(disposition.Id);
        // ⚠ THE LIVE SHAPE OF `usman-dpeg` ON 2026-08-21: one Signed, Buyer-role NDA with a NULL
        // `Buyer__c`. It passes two of the four predicates and still cannot produce an option.
        NDA__c legacy = TestDataFactory.createDispositionNda(disposition.Id, false);
        legacy.Status__c = 'Signed';
        insert legacy;

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        Assert.isNotNull(context, 'A context is always returned');
        Assert.isNotNull(context.buyers, 'buyers is NEVER null — the LWC iterates it');
        Assert.areEqual(0, context.buyers.size(), 'Empty, and the modal explains it');
        // The broker still resolves — the dialog's empty state is about the BUYER only.
        Assert.isNotNull(context.brokerId, 'An empty picker does not suppress the broker');
    }

    @isTest
    static void buyers_areScopedToThisDisposition() {
        Disposition__c mine = onMarket();
        Disposition__c other = onMarket();
        Contact myBuyer = TestDataFactory.createContact(null, true);
        Contact otherBuyer = TestDataFactory.createContact(null, true);
        signedBuyerNda(mine.Id, myBuyer.Id);
        signedBuyerNda(other.Id, otherBuyer.Id);

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(mine.Id);
        Test.stopTest();

        Set<Id> offered = buyerIdsOf(context);
        Assert.areEqual(1, context.buyers.size(), 'One sale, one buyer list');
        Assert.isTrue(offered.contains(myBuyer.Id), 'This sale\'s buyer');
        Assert.isFalse(offered.contains(otherBuyer.Id), 'Another sale\'s buyer must not leak in');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // NOT-FOUND / NULL CONTRACTS
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void nullDispositionId_returnsAFullyPopulatedEmptyContext_withoutThrowing() {
        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(null);
        Test.stopTest();

        // 🔴 NEVER A THROW. The modal's `@wire` fires before `dispositionId` is set on a slow
        // first render, and an exception there would flash an error toast on a dialog that is
        // about to work perfectly.
        Assert.isNotNull(context, 'A null Id still returns a context');
        Assert.isNull(context.brokerId, 'No broker');
        Assert.areEqual('', context.brokerName, 'A STRING, never null — see the DTO');
        Assert.areEqual('', context.brokerSource, 'A STRING, never null');
        Assert.isNotNull(context.buyers, 'buyers is never null');
        Assert.areEqual(0, context.buyers.size(), 'And empty');
        Assert.areEqual(true, context.isOnMarket, 'Defaults to the On_Market branch');
    }

    @isTest
    static void deletedDisposition_degradesInsteadOfThrowing() {
        Disposition__c ghost = onMarket();
        Id deletedId = ghost.Id;
        delete ghost;

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(deletedId);
        Test.stopTest();

        // The record-type fallback is DispositionDomain.recordTypeNameOf's own (`On_Market` for a
        // null/Master row), reused rather than re-derived — so an unreadable parent answers the
        // same way a Master-record-type row does, in this class and in
        // DispositionApprovalService alike.
        Assert.isNotNull(context, 'A missing parent is a degrade, not an exception');
        Assert.isNull(context.brokerId, 'Nothing to resolve');
        Assert.areEqual(true, context.isOnMarket, 'The shared On_Market fallback');
        Assert.areEqual(0, context.buyers.size(), 'And no buyers');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BUDGET — a CEILING, asserted, not described
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void budget_onMarketCostsAtMostThreeQueries_constantInBuyerCount() {
        Disposition__c disposition = onMarket();
        appointBovBroker(disposition.Id);
        // TEN buyers. If any read were per-buyer this would be visibly more than three.
        for (Integer i = 0; i < 10; i++) {
            Contact buyer = TestDataFactory.createContact(null, true);
            signedBuyerNda(disposition.Id, buyer.Id);
        }

        Test.startTest();
        Integer before = Limits.getQueries();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(10, context.buyers.size(), 'All ten buyers are offered');
        // 🔴 THE CEILING, NOT A DESCRIPTION. Parent + Selected BOV + buyer NDAs. A fourth query
        // added later is invisible on a single-record screen and would only surface as latency.
        Assert.areEqual(3, used,
            'On-market costs exactly 3 SOQL regardless of how many buyers there are');
    }

    @isTest
    static void budget_offMarketCostsTwoQueries_theBovReadIsSkippedEntirely() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);
        Contact buyer = TestDataFactory.createContact(null, true);
        signedBuyerNda(disposition.Id, buyer.Id);

        Test.startTest();
        Integer before = Limits.getQueries();
        DispositionOfferFormService.getFormContext(disposition.Id);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        // 🔴 THE BOV READ IS INSIDE THE RECORD-TYPE BRANCH, NOT BEFORE IT. Hoisting it out —
        // which is the shape a "read both, prefer one" refactor takes — would cost every
        // off-market dialog an extra query for a value it must not use, and would ALSO defeat
        // the cross-contamination test above by making the wrong value available.
        Assert.areEqual(2, used, 'Off-market skips the BOV read entirely');
    }

    @isTest
    static void budget_nullIdCostsZeroQueries() {
        Test.startTest();
        Integer before = Limits.getQueries();
        DispositionOfferFormService.getFormContext(null);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, used,
            'The wire can fire before dispositionId is set; that must be free');
    }
}
