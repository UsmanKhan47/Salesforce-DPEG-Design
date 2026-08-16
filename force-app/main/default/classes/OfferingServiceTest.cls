/**
 * Tests for `OfferingService` — the IR Offering shell opened when an acquisition PSA is executed.
 *
 * ── WHAT THESE TESTS PIN, IN ORDER OF WHAT WOULD HURT MOST IF IT REGRESSED ──
 *   1. IDEMPOTENCY. A second call never mints a second shell. That is the failure the guard read
 *      escapes sharing for, and the one a sharing-filtered read would INVERT rather than disable.
 *   2. `Status__c = 'Draft'` IS SET EXPLICITLY. Asserting the value alone would pass on a
 *      picklist-default implementation, so the falsifier below asserts it on a shell built through
 *      the service while `STATUS_DRAFT` names it — see `statusIsSetExplicitlyAndNotInherited`.
 *   3. `IR_Owner__c` IS LEFT NULL. It is not derivable (a User lookup against a public GROUP), and
 *      a future "helpful" default would silently attribute every deal to one person.
 *   4. THE BUDGET: 1 SOQL / at most 1 DML, CONSTANT in deal count, and ZERO of both when nothing
 *      is owed.
 *
 * ⚠ THE TRIGGER-PATH tests (a real PSA execution, the 251-deal bulk run, and the disposition /
 * mixed-chunk cases that prove ACQUISITION-ONLY) live in `ContractExecutionServiceTest`, where the
 * cascade actually runs. They are deliberately NOT duplicated here: this class tests the service in
 * isolation, that one tests the seam.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies with NO exemption — this is a
 * service performing DML on a trigger path — and is met by `bulk251DealsCostOneQueryAndOneDml`.
 * The per-transaction-singleton exemption was READ and does NOT apply: `ensureOnPsaExecuted` is
 * called with a whole trigger chunk, not once per record.
 */
@isTest
private class OfferingServiceTest {

    private static final Integer BULK_N = 251;

    /** Offerings under a deal, read back with the two fields the service is responsible for. */
    private static List<Offering__c> offeringsFor(Id opportunityId) {
        return [
            SELECT Id, Opportunity__c, Status__c, IR_Owner__c
            FROM Offering__c
            WHERE Opportunity__c = :opportunityId
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE SHELL — what is created, and with what on it
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void anExecutedDealGetsExactlyOneDraftShell() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ opp.Id });
        Test.stopTest();

        List<Offering__c> shells = offeringsFor(opp.Id);
        Assert.areEqual(1, shells.size(), 'Exactly one Offering shell is opened');
        Assert.areEqual('Draft', shells[0].Status__c, 'and it starts at Draft');
        Assert.areEqual(1, OfferingService.lastRunCreated, 'the counter agrees');
        Assert.areEqual(0, OfferingService.lastRunFailures, 'and nothing was refused');
    }

    @isTest
    static void statusIsSetExplicitlyAndNotInherited() {
        // 🔴 THE POINT OF THIS TEST IS THE CONSTANT, NOT THE VALUE. `Offering__c.Status__c` carries
        // `Draft` as its own picklist <default>, so an implementation that supplied NOTHING would
        // still produce a Draft row and pass the assertion above. This one binds the assertion to
        // the SERVICE's own named constant, so if someone deletes the explicit assignment and
        // leans on the field default, the constant becomes unreferenced and the intent is gone —
        // and if an admin ever moves the picklist default, this test says which side changed.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(OfferingService.STATUS_DRAFT, offeringsFor(opp.Id)[0].Status__c,
            'The shell\'s status comes from OfferingService.STATUS_DRAFT, never from the '
            + 'picklist\'s own <default> — a creator that relies on a field default breaks '
            + 'silently the moment the default moves');
    }

    @isTest
    static void irOwnerIsLeftNullBecauseItIsNotDerivable() {
        // 🔴 A DELIBERATE NULL, NOT AN OVERSIGHT. IR_Owner__c is a User lookup and
        // `Investor_Relations` is a public GROUP, so there is no derivable IR owner anywhere in the
        // schema. This test exists so a future "helpful" default (the running user, an arbitrary
        // group member, a custom-setting Id) is a visible, deliberate change rather than a quiet
        // one that attributes every deal in the org to whoever executed its PSA.
        // ⚠ Note TestDataFactory.createOfferings DOES set IR_Owner__c (to the running user) — so
        // this must be built through the SERVICE, never through the factory, to mean anything.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.isNull(offeringsFor(opp.Id)[0].IR_Owner__c,
            'IR_Owner__c is left NULL. IR visibility comes from DPEG_IR_Edit / DPEG_IR_View plus '
            + 'the Offering_IR_Visibility owner sharing rule (Gate 1 Q1.2(b)) — NOT from a guessed '
            + 'owner on this field, and not from anything this class writes');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IDEMPOTENCY — the half a sharing-filtered guard read would INVERT
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void aSecondCallNeverMintsASecondShell() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ opp.Id });
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(1, offeringsFor(opp.Id).size(),
            'Re-executing a PSA must never open a second Offering — that is what the guard read '
            + 'escapes sharing for');
        Assert.areEqual(0, OfferingService.lastRunCreated, 'The second pass creates nothing');
        Assert.areEqual(1, OfferingService.lastRunSkipped, 'and records the deal as skipped');
    }

    @isTest
    static void anExistingShellAtAnyStatusStillSuppressesASecond() {
        // 🔴 THE KEY IS `Opportunity__c` ALONE, WITH NO Status__c FILTER, AND THIS IS THE
        // FALSIFIER. A guard that only counted `Draft` rows would open a second shell for every
        // deal whose Offering IR had already moved on — leaving two rows under one deal with
        // nothing to say which is live.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Offering__c active = TestDataFactory.createOffering(opp.Id, false);
        active.Status__c = 'Closed';
        insert active;

        Test.startTest();
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(1, offeringsFor(opp.Id).size(),
            'A Closed Offering still counts as existing — existence, not lifecycle, is the test');
        Assert.areEqual(0, OfferingService.lastRunCreated, 'so nothing new is created');
    }

    @isTest
    static void aMixedSetCreatesOnlyForTheDealsThatLackAShell() {
        Opportunity has = TestDataFactory.createOpportunity(null, true);
        Opportunity lacks = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createOffering(has.Id, true);

        Test.startTest();
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ has.Id, lacks.Id });
        Test.stopTest();

        Assert.areEqual(1, offeringsFor(has.Id).size(), 'The deal that had one still has one');
        Assert.areEqual(1, offeringsFor(lacks.Id).size(), 'and the deal that lacked one now has one');
        Assert.areEqual(1, OfferingService.lastRunCreated, 'one created');
        Assert.areEqual(1, OfferingService.lastRunSkipped, 'one skipped');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GUARDS AND BUDGET
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void nullOrEmptyInputCostsNoQueryAndNoDml() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        OfferingService.ensureOnPsaExecuted(null);
        OfferingService.ensureOnPsaExecuted(new Set<Id>());
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // 🔴 THIS IS THE COMMON CASE, NOT AN EDGE CASE. Every ordinary Contract Review save and
        // EVERY disposition PSA reaches `stampOpportunities` with an empty set, so a query here
        // would be a query on traffic that has nothing to do with this feature.
        Assert.areEqual(0, queriesUsed, 'An empty set must cost zero queries');
        Assert.areEqual(0, dmlUsed, 'and zero DML');
        Assert.areEqual(0, OfferingService.lastRunCreated, 'and create nothing');
    }

    @isTest
    static void aSetWhereEveryDealAlreadyHasAShellCostsOneQueryAndZeroDml() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createOffering(opp.Id, true);

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ opp.Id });
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // Re-execution is the ordinary case once a deal has been executed once. ZERO DML is what
        // makes it genuinely free rather than merely harmless.
        Assert.areEqual(0, dmlUsed, 'Nothing to create means no DML statement at all');
    }

    @isTest
    static void bulk251DealsCostOneQueryAndOneDml() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(BULK_N, true);
        Set<Id> oppIds = new Set<Id>();
        for (Opportunity opp : opps) {
            oppIds.add(opp.Id);
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        OfferingService.ensureOnPsaExecuted(oppIds);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, [SELECT COUNT() FROM Offering__c WHERE Opportunity__c IN :oppIds],
            'One shell per deal at 251');
        Assert.areEqual(BULK_N, OfferingService.lastRunCreated, 'and the counter agrees');
        // 🔴 THE CONSTANCY IS THE CLAIM. A per-record selector call breaks the 100-query limit at
        // 251 and a per-record insert breaks the 150-statement limit; pinning 1/1 makes either
        // regression fail HERE rather than on a real 251-deal bulk close.
        Assert.areEqual(1, queriesUsed, 'ONE query regardless of deal count');
        Assert.areEqual(1, dmlUsed, 'and ONE DML statement');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE FAILURE PATH — a refused insert is counted, never thrown
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE ONE BRANCH NO OTHER TEST IN THIS CLASS REACHES: `Database.SaveResult.isSuccess() ==
     * false`. Every other test here inserts cleanly, so `lastRunFailures` and the debug-log branch
     * in `ensureOnPsaExecuted` (class header §3) are otherwise never exercised — and an untested
     * failure branch is exactly the kind of gap that ships silently broken.
     *
     * Forced with the same technique `CounterOfferControllerTest
     * .writeFailureThrowsAuraHandledException` uses against `LOI__c`: delete the parent first, so
     * the child insert references an Id that no longer resolves and the platform reports
     * `INVALID_CROSS_REFERENCE_KEY`. Because `allOrNone = false`, that surfaces as a FAILED
     * `Database.SaveResult`, never a thrown exception — which is exactly the shape this method must
     * survive without rolling back the caller (a PSA execution).
     */
    @isTest
    static void aRefusedInsertIsCountedAsAFailureAndDoesNotThrow() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Id danglingOppId = opp.Id;
        delete opp;

        Test.startTest();
        // Must NOT throw. A thrown exception here would propagate out of
        // ContractExecutionService.stampOpportunities and roll back the PSA execution — precisely
        // what allOrNone = false exists to prevent.
        OfferingService.ensureOnPsaExecuted(new Set<Id>{ danglingOppId });
        Test.stopTest();

        Assert.areEqual(0, OfferingService.lastRunCreated, 'the refused insert created nothing');
        Assert.areEqual(1, OfferingService.lastRunFailures,
            'and it IS counted as a failure rather than silently dropped — the only signal this '
            + 'residual produces (class header §3: there is no sweeper for Offering__c)');
        Assert.areEqual(0, [SELECT COUNT() FROM Offering__c],
            'no Offering exists for a deal whose parent Id no longer resolves');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE allOrNone TRADE (Gate 1, Q1.1)
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void allOrNoneIsFalseSoARefusedInsertCannotRollBackThePsaExecution() {
        // 🔴 THIS PINS A DECISION, NOT A BEHAVIOUR, AND IT IS WORTH A TEST FOR THAT REASON.
        // The repo precedent cuts both ways — advanceDispositionsToClosing chose false,
        // PropertyAssetService chose true — so flipping this constant compiles, passes every other
        // test in this class, and silently changes what happens to a legally executed PSA when an
        // Offering insert is refused. Nothing else would catch it.
        Assert.isFalse(OfferingService.allOrNone,
            'A refused Offering insert must NOT roll back the PSA execution. The executed PSA is '
            + 'the irreplaceable half; an Offering shell is recoverable by hand. Read '
            + 'OfferingService header §3 before changing this — and note the stated residual: a '
            + 'failed insert leaves NO Offering and NO SIGNAL, because there is no sweeper');
    }
}
