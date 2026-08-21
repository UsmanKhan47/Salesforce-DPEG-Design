/**
 * @description Test class for DispositionDealSummaryController.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 RETRACTED 2026-08-20 (code review C4). THE ARGUMENT BELOW IS QUOTED IN FULL BECAUSE IT IS
 *    NEARLY RIGHT, AND ITS ONE FAULT IS THE INSTRUCTIVE PART. Quote-and-retract, not deletion —
 *    a reader who arrives holding the old reasoning needs to see it refuted, not vanish.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * It used to say:
 *
 *   > "⚠ THE `catch (Exception e)` BOUNDARY IS NOT COVERED HERE, AND THAT IS A KNOWN, ACCEPTED GAP
 *   > — NOT AN OVERSIGHT. ... every read `DispositionDealSummaryService.summarise` performs is
 *   > already wrapped in its OWN narrow, row-level try/catch (four of them), so by construction the
 *   > only exceptions able to reach the controller's catch are ones no row-level catch could
 *   > sensibly own: a heap/CPU governor fault, or a platform fault. Apex offers no supported way to
 *   > manufacture either from a test method without actually exhausting that limit, and
 *   > `System.LimitException: Apex CPU time limit exceeded` specifically is UNCATCHABLE even by
 *   > `catch (Exception e)` — triggering it would fail this test method outright rather than prove
 *   > the controller's translation. ... A `@TestVisible` seam was deliberately NOT added here ...
 *   > it would put test-only branching into a live read path to cover a handful of defensive lines."
 *
 * 🔴 WHY THAT WAS WRONG. Read it to its own conclusion: the entire residue it identifies is a
 * `System.LimitException`, and it then concedes — correctly — that `catch (Exception e)` CANNOT
 * CATCH THAT AT ALL. So the paragraph does not prove the catch is uncoverable. It proves the catch
 * is **DEAD**: if the only thing that can reach a catch is a thing the catch cannot catch, nothing
 * reaches it. "Untestable" and "unreachable" are different claims with different remedies, and the
 * argument silently substituted the first for the second.
 *
 * The ⚠ SECOND, LARGER FAULT is that an accepted coverage gap was treated as free. It is not:
 * a `RunSpecifiedTests` production deploy enforces **per-class 75%** through `codeCoverageWarnings`,
 * and this class sat at 33%. This repo has already had a deploy report "689/689 deployed, 0 errors"
 * and roll everything back on exactly that signal — which no error counter shows. A documented gap
 * would have failed the deploy just as loudly as an undocumented one.
 *
 * ✅ THE FIX WAS NOT A TEST SEAM — IT WAS A REAL GUARD THE CLASS WAS MISSING. The controller now
 * refuses an Id of the wrong SObject type before the try, exactly as its sibling
 * `DispositionBuyerTimelineController` (built the same day) already did. That closes a genuine
 * wiring hazard — every read behind this card is `WHERE Disposition__c = :id`, which matches no
 * rows rather than throwing, so a foreign Id renders a confident permanent EMPTY card — AND it
 * gives the class a reachable, assertable throw path. The two cards no longer disagree about
 * whether a foreign Id is an error.
 *
 * ⚠ THE ORIGINAL PARAGRAPH'S NARROW CLAIM SURVIVES, SCOPED CORRECTLY: the `catch (Exception e)`
 * itself is still not exercised below, and still should not be forced with a `@TestVisible` seam.
 * It is a mask-of-last-resort for a platform fault, not a branch with a behaviour to prove. What
 * changed is that the class no longer DEPENDS on covering it to clear the deploy gate.
 *
 * What IS covered: the null-Id empty-summary contract, the wrong-SObject-type refusal, and that the
 * controller is a genuinely thin, unmodified pass-through of everything the service computes (the
 * delegation itself, proved on real data across all three rows).
 *
 * @author Unit Testing Agent
 * @see force-app/main/default/classes/DispositionBuyerTimelineTest.cls
 *      (`controller_withWrongSObjectType_throwsAuraHandledException` — the template copied below)
 */
@isTest
private class DispositionDealSummaryControllerTest {

    @TestSetup
    static void setupTestData() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Disposition__c newDisposition() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        return TestDataFactory.createDisposition(asset.Id, true);
    }

    @isTest
    static void getDealSummary_nullId_returnsEmptySummaryNotError() {
        Test.startTest();
        DispositionDealSummaryService.DealSummary summary =
            DispositionDealSummaryController.getDealSummary(null);
        Test.stopTest();

        Assert.isNotNull(summary, 'A null Id must still return a summary object, never null');
        Assert.isFalse(summary.hasNda, 'Empty summary has no NDA row');
        Assert.isFalse(summary.hasLoi, 'Empty summary has no LOI row');
        Assert.isFalse(summary.hasPsa, 'Empty summary has no PSA row');
    }

    /**
     * 🔴 A WRONG SOBJECT TYPE IS REFUSED, LOUDLY — AND A NULL IS NOT (see the test above). Binding a
     * foreign Id into `WHERE Disposition__c = :id` throws NOTHING; it simply matches no rows. So
     * without this guard a card wired to the wrong `record-id` would render a confident, permanent
     * EMPTY summary on all 11 disposition stages, and nobody would ever learn it was pointed at the
     * wrong record — the failure would look exactly like a sale that has not started yet.
     *
     * ⚠ THE MESSAGE ASSERTION IS NOT DECORATION. It pins that the refusal came from the guard
     * OUTSIDE the try and not from the generic `catch (Exception)` inside it. If the guard were ever
     * moved into the try, this test would still see an `AuraHandledException` — and only the message
     * would reveal that a precise wiring diagnosis had been replaced by "could not be loaded".
     *
     * Copied from `DispositionBuyerTimelineTest.controller_withWrongSObjectType_throwsAuraHandledException`.
     */
    @isTest
    static void getDealSummary_wrongSObjectType_throwsAuraHandledException() {
        Contact notADisposition = TestDataFactory.createContact(null, true);
        Boolean threw = false;

        Test.startTest();
        try {
            DispositionDealSummaryController.getDealSummary(notADisposition.Id);
            Assert.fail('A Contact Id must not be accepted as a Disposition Id');
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Disposition'),
                'The message must NAME the expected object rather than being the generic '
                + 'read-failure text — a wiring mistake and a permission gap need different fixes');
            Assert.isFalse(e.getMessage().contains('Refresh the page'),
                'and specifically must not be the generic read-failure message, which would mean '
                + 'the guard had fallen inside the try and been swallowed by the outer catch');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The guard must fire');
    }

    /**
     * Delegation proof: the controller must return exactly what the service computed, across all
     * three rows, with no controller-side transformation or omission.
     */
    @isTest
    static void getDealSummary_realDisposition_delegatesTheFullServiceResult() {
        Disposition__c d = newDisposition();
        NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
        nda.Status__c = 'Signed';
        nda.Date_Signed__c = Date.today();
        insert nda;
        LOI__c loi = TestDataFactory.createDispositionLoi(d.Id, false);
        loi.Stage__c = 'Under Review';
        loi.Offer_Price__c = 1500000;
        loi.Ball_In_Court__c = 'Buyer';
        insert loi;
        Contract_Review__c cr = TestDataFactory.createDispositionContractReview(d.Id, false);
        // ⚠ REPOINTED 2026-08-21 from 'Ready for Execution', which the user removed from the
        // Disposition_PSA record type. 'Signed' is that record type's terminal now, and because
        // Negotiation_Status__c is a restricted picklist the old value is refused by Apex DML —
        // this line was a hard failure, not a stale-but-passing fixture.
        cr.Negotiation_Status__c = 'Signed';
        insert cr;

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary =
            DispositionDealSummaryController.getDealSummary(d.Id);
        Test.stopTest();

        Assert.isTrue(summary.hasNda, 'NDA row must be populated through the controller');
        Assert.areEqual('Signed', summary.ndaStatus, 'NDA status must pass through unmodified');
        Assert.isTrue(summary.hasLoi, 'LOI row must be populated through the controller');
        Assert.areEqual('Under Review', summary.loiStage, 'LOI stage must pass through unmodified');
        Assert.areEqual(1500000, summary.loiOfferPrice, 'LOI offer price must pass through unmodified');
        Assert.areEqual('Buyer', summary.loiBallInCourt, 'LOI ball-in-court must pass through unmodified');
        Assert.isTrue(summary.hasPsa, 'PSA row must be populated through the controller');
        Assert.areEqual('Signed', summary.psaStatus, 'PSA status must pass through unmodified');
        Assert.isFalse(summary.ndaCountsUnavailable, 'No degrade expected on a fully-granted read');
        Assert.isFalse(summary.ndaUnavailable, 'No degrade expected on a fully-granted read');
        Assert.isFalse(summary.loiUnavailable, 'No degrade expected on a fully-granted read');
        Assert.isFalse(summary.psaUnavailable, 'No degrade expected on a fully-granted read');
    }
}
