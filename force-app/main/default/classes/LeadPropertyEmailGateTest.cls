/**
 * @description Negative-test coverage for TWO Lead validation rules, both gated on Property
 * Address / Email:
 *   - Property_And_Email_Required_To_Progress (VR-L1) - blocks the Status transition into
 *     Qualified. Covered by addressLessLead_blockedFromQualified_butAlwaysDisqualifiable
 *     (closes code-review gap W2).
 *   - Property_And_Email_Required_To_Convert (VR-L2) - blocks Database.convertLead itself.
 *     Covered by the three methods added 2026-08-04. VR-L2 previously had NO direct test; it
 *     was only ever incidentally exercised by LeadConvertServiceTest.blankLeadFieldsLeaveTargetsNull,
 *     which was repaired to stop tripping it - leaving VR-L2 with zero negative coverage until now.
 *
 * Pins both directions the design doc calls out for VR-L1: an address-less Lead is blocked from
 * New -> Qualified, AND the SAME Lead can still go New -> Disqualified. The second assertion
 * pins the deliberate Disqualified carve-out - a Lead with no address must always be
 * disqualifiable, mirroring the Opportunity Dead/Pass invariant - which nothing else defends.
 *
 * === (*) THE JUSTIFICATION ABOVE WAS AMENDED 2026-08-30. THE LEAD BEHAVIOUR IS UNCHANGED. ===
 * RETRACTED, verbatim: "mirroring the Opportunity Dead/Pass invariant". That invariant - recorded
 * in Opportunity/validationRules/No_Backward_Stage_Movement's header as "the user-required
 * invariant that Dead/Pass stay reachable from every stage" - NO LONGER HOLDS UNIVERSALLY on
 * Opportunity. Dead_Pass_Not_Allowed_From_Closed_Won (new, 2026-08-30, user decision reaffirmed
 * after the consequence was stated) blocks Closed Won -> Dead/Pass, so Opportunity's off-ramp is
 * now reachable from every stage EXCEPT Closed Won.
 *
 * THE CORRECTED JUSTIFICATION, WHICH IS STRONGER AND DOES NOT DEPEND ON THE OPPORTUNITY AT ALL:
 * a junk Lead with no address must always be disqualifiable, because Disqualified is the ONLY
 * terminal state a Lead has and VR-L1 gates the very fields a junk Lead is missing - so gating
 * Disqualified would make an unusable Lead permanently unclosable. That is a fact about Lead, not
 * an analogy to Opportunity.
 *
 * (*) 🔴 THE ANALOGY MOVED; THE LEAD CARVE-OUT DID NOT, AND MUST NOT. Nothing in the 2026-08-30
 * decision was about Lead. Do NOT "harmonise" this test, Property_And_Email_Required_To_Progress,
 * or the Lead status model by adding a Disqualified restriction to mirror the new Opportunity
 * rule. The test below is unchanged and still passes.
 *
 * ⚠ VR-L2 IS CONDITIONAL ON AN ORG SETTING. Property_And_Email_Required_To_Convert only fires
 * when "Require Validation for Converted Leads" (shouldLeadConvertRequireValidation, Setup ->
 * Lead Settings) is ON - see the XML comment in
 * Lead/validationRules/Property_And_Email_Required_To_Convert.validationRule-meta.xml. Verified
 * ON in usman-dpeg by retrieving Settings:LeadConfig directly from the org (the repo's
 * settings/LeadConfig.settings-meta.xml is forceignored and was measurably stale - it differed
 * from the org on two other fields, so it cannot be trusted as evidence either way). If the
 * negative tests below ever red with NO DmlException thrown (the Lead converts successfully
 * despite a blank required field), diagnose "someone turned the org setting off" FIRST, before
 * assuming the validation rule itself regressed - the rule fails OPEN (silently permissive), not
 * closed, when the setting is off.
 *
 * @author Unit Testing Agent
 */
@isTest
private class LeadPropertyEmailGateTest {

    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    @isTest
    static void addressLessLead_blockedFromQualified_butAlwaysDisqualifiable() {
        Lead l = TestDataFactory.createLead(false);
        l.Property_Address__c = null; // TestDataFactory fills this by default (F7); clear it deliberately.
        insert l; // ISCHANGED(Status) is false on insert, so the gate is bypassed here.

        Boolean blocked = false;
        try {
            l.Status = 'Qualified';
            update l;
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('Property Address and Email are both required before this lead can move forward'),
                'Moving an address-less Lead to Qualified should surface the field-gate message, got: '
                + e.getMessage());
        }
        System.assert(blocked, 'An address-less Lead must not be able to move to Qualified');

        System.assertEquals('New',
            [SELECT Status FROM Lead WHERE Id = :l.Id].Status,
            'A rejected save must leave Status untouched');

        // Disqualified is deliberately NOT in the rule's gated-status list - a junk lead with no
        // address must always be disqualifiable, because Disqualified is the only terminal state a
        // Lead has and VR-L1 gates exactly the fields such a Lead is missing. Same record,
        // opposite outcome.
        //
        // ⚠ AMENDED 2026-08-30 - see the class header. This comment used to justify the carve-out
        // as "the Lead's equivalent of the Opportunity's Dead/Pass off-ramp", which was true when
        // Dead/Pass was reachable from EVERY Opportunity stage. It no longer is
        // (Dead_Pass_Not_Allowed_From_Closed_Won). The carve-out stands on its own Lead-side
        // reasoning; the Opportunity analogy is what was removed, not the behaviour.
        Test.startTest();
        l.Status = 'Disqualified';
        update l;
        Test.stopTest();

        System.assertEquals('Disqualified',
            [SELECT Status FROM Lead WHERE Id = :l.Id].Status,
            'An address-less Lead must always be reachable as Disqualified');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // VR-L2 - Property_And_Email_Required_To_Convert. Gates Database.convertLead
    // itself, not just the Status transition into Qualified (that is VR-L1, above).
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void blankPropertyAddress_blocksConversion() {
        // TestDataFactory.createLead fills both Property_Address__c and Email by default
        // (see TestDataFactory.createLeads) - clear only the address so this test isolates
        // that half of the rule's OR condition.
        Lead l = TestDataFactory.createLead(false);
        l.Property_Address__c = null;
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Boolean blocked = false;
        Test.startTest();
        try {
            Database.convertLead(lc);
            System.assert(false, 'Converting a Lead with a blank Property Address should have been refused');
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('Property Address and Email are both required before this lead can be converted.'),
                'Should surface VR-L2\'s own errorMessage text, so this test cannot pass because of '
                + 'an unrelated failure. Got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(blocked, 'A Lead with a blank Property Address must not convert');
        System.assertEquals(false,
            [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
            'A refused conversion must leave the Lead unconverted');
    }

    @isTest
    static void blankEmail_blocksConversion() {
        // Mirror of the above, isolating the OTHER half of the rule's OR condition. Property
        // Address stays populated (TestDataFactory default); only Email is cleared.
        Lead l = TestDataFactory.createLead(false);
        l.Email = null;
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Boolean blocked = false;
        Test.startTest();
        try {
            Database.convertLead(lc);
            System.assert(false, 'Converting a Lead with a blank Email should have been refused');
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('Property Address and Email are both required before this lead can be converted.'),
                'Should surface VR-L2\'s own errorMessage text, so this test cannot pass because of '
                + 'an unrelated failure. Got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(blocked, 'A Lead with a blank Email must not convert');
        System.assertEquals(false,
            [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
            'A refused conversion must leave the Lead unconverted');
    }

    /**
     * The positive direction. Without this, a regression that blocked ALL conversions
     * (not just the blank-field ones VR-L2 is meant to catch) would still pass this class.
     */
    @isTest
    static void bothFieldsPopulated_conversionSucceeds() {
        Lead l = TestDataFactory.createLead(false); // both Property_Address__c and Email are set
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Test.startTest();
        Database.LeadConvertResult res = Database.convertLead(lc);
        Test.stopTest();

        System.assert(res.isSuccess(),
            'A Lead with both Property Address and Email populated must convert successfully');
        System.assertEquals(true,
            [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
            'The Lead should be converted');
    }
}
