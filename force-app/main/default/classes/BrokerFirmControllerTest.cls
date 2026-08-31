/**
 * Tests BrokerFirmController.getBrokerFirm — the Opportunity record-page sidebar's
 * brokerage-firm summary (firm name, broker contact, firm-level deal counts).
 *
 * ═══ 🔴 THE THREE COUNTS BECAME ROLL-UP READS ON 2026-08-30 (design Item 6.1) ═══
 * They used to be summed in Apex from `OpportunitySelector.countByStageForAccount`, a
 * `GROUP BY StageName` aggregate with `'Closed Won'` / `'Dead/Pass'` compared as strings in the
 * controller. They now come from three native Account roll-up summaries —
 * `Total_Deals_Submitted__c`, `Deals_Won__c`, `Deals_Lost__c` — spanned onto the row the sidebar
 * already loads.
 *
 * ⚠ THE EXPECTED NUMBERS DID NOT CHANGE, AND THAT IS DELIBERATE. Every assertion below (4/2/1,
 * 1/0/0, 251/126/125) is the value the old Apex computation produced, kept EXACTLY. The point of
 * the repoint is that the sidebar and the `Broker_Leaderboard` report stop being two independent
 * derivations of one fact; if the roll-up FILTERS in metadata disagree with what the Apex used to
 * do, these unchanged numbers are precisely where it shows. Rewriting them to match a new
 * behaviour would throw that away.
 *
 * 🔴 WHAT THESE TESTS NOW DEPEND ON, STATED SO A FAILURE IS DIAGNOSABLE:
 *   1. THE THREE ROLL-UP FIELDS MUST EXIST. They are created by the parallel admin stream. Until
 *      they are deployed this class does not COMPILE, along with `OpportunitySelector`.
 *   2. THE ROLL-UPS MUST RECALCULATE WITHIN THE TEST TRANSACTION. Account->Opportunity roll-up
 *      summaries are maintained by the platform on child DML, like master-detail roll-ups. ⚠ IF
 *      EVERY COUNT ASSERTION BELOW SUDDENLY READS 0 WHILE THE FIXTURE IS CORRECT, THAT IS THE
 *      DIAGNOSIS — the recalculation is not landing inside the transaction — NOT a defect in
 *      `getBrokerFirm`. A roll-up cannot be written directly even in a test (they are read-only at
 *      the API), so there is no way to fake the value; the honest remedy would be to move these
 *      three assertions onto a re-queried Account after `Test.stopTest()`, or to accept that the
 *      COUNTS are covered by the roll-up definitions and pin only the wiring here.
 *   3. FLS on the three fields. The read is `WITH USER_MODE`; a missing grant throws for the whole
 *      row and surfaces as `readPathThrowsAuraHandledException`-shaped failure everywhere at once.
 */
@isTest
private class BrokerFirmControllerTest {

    @isTest
    static void nullOpportunityId_returnsEmptyDefault() {
        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(null);
        Test.stopTest();

        System.assert(!bf.hasFirm, 'No firm for a null opportunityId');
        System.assertEquals(null, bf.firmName, 'firmName stays null');
        System.assertEquals(null, bf.brokerName, 'brokerName stays null');
        System.assertEquals(0, bf.dealsSubmitted, 'dealsSubmitted stays 0');
        System.assertEquals(0, bf.dealsWon, 'dealsWon stays 0');
        System.assertEquals(0, bf.dealsLost, 'dealsLost stays 0');
    }

    @isTest
    static void opportunityWithNoAccount_returnsEmptyDefault() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(opp.Id);
        Test.stopTest();

        System.assert(!bf.hasFirm, 'No Account behind the deal means no firm was found');
        System.assertEquals(null, bf.firmName, 'firmName stays null when there is no firm');
        System.assertEquals(0, bf.dealsSubmitted, 'dealsSubmitted stays 0 for the no-Account branch');
    }

    @isTest
    static void firmWithNoBrokerContact_countsDealsAcrossStagesWithoutBrokerName() {
        // ⚠ THE THREE COUNTS BELOW ARE NOW ROLL-UP READS, and the numbers are unchanged on
        // purpose — see the class header. The mixed stage set is what makes the test discriminate:
        // an unfiltered roll-up wired into `dealsWon` would report 4 here, not 2.
        Account firm = TestDataFactory.createAccount(true);
        // No Contact created under this Account: the earliest-Contact lookup returns null.
        Opportunity target = TestDataFactory.createOpportunity(firm.Id, true); // default 'New' stage
        Opportunity won1 = TestDataFactory.createOpportunity(firm.Id, false);
        won1.StageName = 'Closed Won';
        Opportunity won2 = TestDataFactory.createOpportunity(firm.Id, false);
        won2.StageName = 'Closed Won';
        Opportunity lost = TestDataFactory.createOpportunity(firm.Id, false);
        lost.StageName = 'Dead/Pass';
        // ⚠ REQUIRED AS OF 2026-08-30. `Rejection_Reason_Required_On_Dead` fires on INSERT as well
        // as on a stage change, so this fixture — which inserts straight at Dead/Pass — now needs
        // a reason. 'Wrong Market' is present on BOTH surviving Opportunity record types (Land
        // and Retail; Commercial was deleted 2026-08-30 — re-verified against the surviving files).
        lost.Rejection_Reason__c = 'Wrong Market';
        insert new List<Opportunity>{ won1, won2, lost };

        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(target.Id);
        Test.stopTest();

        System.assert(bf.hasFirm, 'An Account behind the deal means a firm was found');
        System.assertEquals(firm.Name, bf.firmName, 'firmName mirrors the Account name');
        System.assertEquals(null, bf.brokerName, 'No Contact under the Account leaves brokerName null');
        System.assertEquals(4, bf.dealsSubmitted, 'All 4 opportunities under the firm are counted');
        System.assertEquals(2, bf.dealsWon, 'The two Closed Won opportunities are counted as won');
        System.assertEquals(1, bf.dealsLost, 'The one Dead/Pass opportunity is counted as lost');
    }

    @isTest
    static void firmWithBrokerContact_returnsEarliestContactName() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createContact(firm.Id, true);
        Opportunity opp = TestDataFactory.createOpportunity(firm.Id, true);

        // Contact.Name is a compound field the platform computes server-side; the
        // in-memory `broker` from the DML insert above never has it populated
        // locally, so it must be re-queried to get the real value.
        broker = [SELECT Id, Name FROM Contact WHERE Id = :broker.Id];

        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(opp.Id);
        Test.stopTest();

        System.assert(bf.hasFirm, 'Firm should be found');
        System.assertEquals(broker.Name, bf.brokerName, 'brokerName mirrors the Contact under the firm Account');
        System.assertEquals(1, bf.dealsSubmitted, 'One opportunity submitted under this firm');
        System.assertEquals(0, bf.dealsWon, 'No Closed Won opportunities yet');
        System.assertEquals(0, bf.dealsLost, 'No Dead/Pass opportunities yet');
    }

    /**
     * Bulk scenario per .claude/rules/bulk-test-rule.md's controller carve-out
     * (single Id in, so no 251-sequential-call loop): a brokerage firm can
     * legitimately accumulate hundreds of Opportunities over its lifetime, and
     * getBrokerFirm must return the right numbers for that firm in ONE call.
     *
     * ═══ 🔴 WHAT THIS TEST MEASURES CHANGED ON 2026-08-30, AND THE FIXTURE IS WHY IT SURVIVED ═══
     * ⚠ RETRACTED, verbatim, from this method's own header: "getBrokerFirm's GROUP BY aggregate
     * must scale to that in ONE call." THERE IS NO AGGREGATE ANY MORE. The counts are read from
     * Account roll-up summaries.
     *
     * The fixture and all three expected numbers are UNCHANGED, and that is what makes this the
     * single most valuable test in the class after the repoint: 251 deals, 126 `Closed Won` and 125
     * `Dead/Pass` were computed by the OLD Apex, so if the new roll-ups' `<summaryFilterItems>`
     * disagree with what that Apex did — a wrong stage literal, a filter on the wrong field, a
     * `count` that quietly became a `sum` — THIS IS WHERE IT SHOWS, at a scale where an off-by-one
     * cannot hide. It is now a CROSS-CHECK BETWEEN APEX AND METADATA, not a scaling test.
     *
     * ⚠ THE STAGES ARE SET AT INSERT, ON PURPOSE, AND TWO 2026-08-30 RULES BEAR ON THAT:
     *   • `Dead_Pass_Not_Allowed_From_Closed_Won` blocks `Closed Won -> Dead/Pass` outright. It is
     *     `PRIORVALUE`/`ISCHANGED`-keyed and therefore cannot fire on an insert, which is why this
     *     fixture — a single insert that assigns each row its final stage — still builds. 🔴 DO NOT
     *     "TIDY" IT INTO AN INSERT-THEN-UPDATE: with 126 Closed Won and 125 Dead/Pass rows, an
     *     update pass would be the exact transition that rule forbids.
     *   • `Rejection_Reason_Required_On_Dead` DOES fire on insert (it was tightened to on
     *     2026-08-30), so every Dead/Pass row below carries a reason. ⚠ This paragraph previously
     *     said "Both rules are ISCHANGED(StageName)-gated and therefore FALSE on insert" — TRUE OF
     *     THE FIRST, FALSE OF THE SECOND. The two rules are gated differently and must not be
     *     reasoned about as a pair.
     */
    @isTest
    static void firmWith251Opportunities_readsTheRollUpsAcrossAllOfThem() {
        Account firm = TestDataFactory.createAccount(true);
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, firm.Id, false);
        for (Integer i = 0; i < opps.size(); i++) {
            opps[i].StageName = Math.mod(i, 2) == 0 ? 'Closed Won' : 'Dead/Pass';
            if (Math.mod(i, 2) != 0) {
                // ⚠ REQUIRED AS OF 2026-08-30 — `Rejection_Reason_Required_On_Dead` now fires on
                // insert. All 125 Dead/Pass rows need one, and an all-or-none `insert` means one
                // missing reason fails the whole 251.
                opps[i].Rejection_Reason__c = 'Wrong Market';
            }
        }
        insert opps;
        Id anchorId = opps[0].Id; // any one of the 251 works as the clicked record

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(anchorId);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        System.assertEquals(251, bf.dealsSubmitted, 'All 251 opportunities under the firm are counted');
        System.assertEquals(126, bf.dealsWon, 'Even indices (126 of 251) are Closed Won');
        System.assertEquals(125, bf.dealsLost, 'Odd indices (125 of 251) are Dead/Pass');

        // 🔴 THE ASSERTION THAT PINS THE REPOINT ITSELF, AND THE REASON IT IS WORTH ITS LINE.
        // Every count assertion above would still pass if someone re-added the `GROUP BY` loop
        // "to be sure" — two sources of truth restored, silently, with the tests green. It fails
        // HERE instead. TWO queries: the deal + its spanned Account, and the broker Contact.
        //
        // ⚠ MEASURED INSIDE THE TRANSACTION. `Test.stopTest()` restores the pre-test governor
        // counters, so the same arithmetic written after it is silently vacuous — a measured trap
        // in this repo, not a stylistic preference.
        System.assertEquals(2, queriesUsed,
            'getBrokerFirm must be exactly TWO queries: selectAccountRefById (deal + spanned '
            + 'Account roll-ups) and the broker Contact lookup. A THIRD means the firm-level '
            + 'GROUP BY aggregate came back and the counts have two sources again');
    }

    // An Opportunity Id that no longer exists makes selectAccountRefById's single-row SOQL
    // throw System.QueryException, exercising getBrokerFirm's read-failure catch which maps
    // it to a user-safe AuraHandledException at the LWC boundary (P6).
    @isTest
    static void readPathThrowsAuraHandledException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Id deletedId = opp.Id;
        delete opp;

        Test.startTest();
        try {
            BrokerFirmController.getBrokerFirm(deletedId);
            Assert.fail('expected AuraHandledException from getBrokerFirm for a deleted Opportunity Id');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'getBrokerFirm read failure maps to AuraHandledException');
        }
        Test.stopTest();
    }
}
