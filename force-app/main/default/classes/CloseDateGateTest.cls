/**
 * @description Negative-test coverage for the Close_Date_Before_About_To_Close validation rule
 * (Opportunity), added to close code-review gap W2.
 *
 * This rule CANNOT fire against any test in this repo's existing suite:
 * TestDataFactory.createOpportunities hardcodes CloseDate = Date.today().addDays(90), so every
 * fixture has a future Close Date by construction. This test sets a past CloseDate explicitly
 * via a preparatory update (which does not touch StageName, so it crosses no stage gate) before
 * attempting the gated transition.
 *
 * @author Unit Testing Agent
 */
@isTest
private class CloseDateGateTest {

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    @isTest
    static void closeDateGate_blocksAboutToCloseEntryWithPastCloseDate() {
        Opportunity o = newOpp('Under Contract (PSA)');
        insert o; // ISCHANGED(StageName) is false on insert, so every gate is bypassed here.
        TestDataFactory.signPrimaryNda(o); // isolate: About to Close entry is ALSO NDA-gated

        // Set an explicit PAST Close Date. This update does not touch StageName, so it crosses no
        // stage gate - it only creates the precondition TestDataFactory's default (today + 90)
        // can never produce.
        o.CloseDate = Date.today().addDays(-5);
        update o;

        Boolean blocked = false;
        try {
            o.StageName = 'About to Close';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains('Set a current Close Date before moving this deal to About to Close'),
                'Entering About to Close with a past Close Date should surface the Close Date message, got: '
                + e.getMessage());
        }
        System.assert(blocked, 'Entering About to Close with a Close Date already in the past must be blocked');

        System.assertEquals('Under Contract (PSA)',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage untouched');
    }
}
