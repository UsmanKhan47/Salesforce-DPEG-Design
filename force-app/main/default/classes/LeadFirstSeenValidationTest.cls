/**
 * Regression pinning for the `Lead.Broker_First_Seen_Is_System_Set` validation rule
 * (FSD Tranche 1, Item 3 — FSD §26 Rule 2).
 *
 *     AND(ISCHANGED(First_Seen_Date__c), NOT(ISBLANK(PRIORVALUE(First_Seen_Date__c))))
 *
 * ── WHY A DEDICATED CLASS FOR A DECLARATIVE RULE ────────────────────────────
 * A validation rule has no Apex to cover, so nothing in a normal test run exercises it on purpose.
 * But this one sits on `First_Seen_Date__c`, which anchors `Lead.BP_Expiry__c` (the 90-day broker
 * protection window), `Days_in_System__c`, `LeadSelector`'s ordering, `LeadFunnelController` and
 * the Lead Funnel Path — so a rule that is one clause too wide silently blocks a live pipeline, and
 * one that is too narrow does nothing. These tests are its falsifiers, in both directions.
 *
 * ⚠ **IT WAS RE-TARGETED FROM THE FIELD THE FSD NAMED, AND THAT WAS A GATE-1 USER DECISION (Q3.3),
 * NOT A UNILATERAL SUBSTITUTION.** The FSD names `Opportunity.Broker_First_Seen__c`; repo-wide grep
 * found NOTHING writes that field — no Apex writer, no Flow writer — so a rule there would lock a
 * permanently-blank field and remove the only route to populating it (a human typing it), i.e. it
 * would be strictly worse than no rule. `CallForOffersService`'s own header records the same
 * finding independently. The full argument lives in the rule's own XML comment.
 *
 * 🔴 **THAT PREMISE EXPIRED ON 2026-08-30 (WS2), AND THE RE-TARGET DECISION DID NOT.**
 * `LeadConvertService.applyDealFields` now copies `Lead.First_Seen_Date__c` into
 * `Opportunity.Broker_First_Seen__c` on every conversion, so the FSD-named field has a real writer
 * and is no longer permanently blank. A sibling rule now exists there —
 * `Opportunity/validationRules/Broker_First_Seen_Is_System_Set` — built ALONGSIDE this one, not
 * instead of it. The paragraph above is left standing and retracted here rather than deleted,
 * because without it a reader finds two identically-named rules on two objects and no record of
 * why the Lead one came first. THIS class still tests only the LEAD rule; the Opportunity rule is
 * covered by the conversion tests in `LeadConvertServiceTest`, where its one legitimate writer is.
 *
 * ── 🔴 ONE BRANCH OF THE FORMULA IS UNREACHABLE IN THIS ORG, AND SAYING SO IS PART OF THE
 *      COVERAGE ────────────────────────────────────────────────────────────
 * The `NOT(ISBLANK(PRIORVALUE(...)))` clause exists to exempt `Lead_Intake_Stamp`, the before-save
 * flow that assigns `First_Seen_Date__c` **only when it IsNull**. But that flow is
 * `RecordBeforeSave` / `CreateAndUpdate` with **no entry filter** (read off the flow file
 * 2026-08-16), so it stamps at INSERT on every single Lead — which means **no Lead in this org can
 * reach an UPDATE with a blank prior value**, and the blank-prior branch cannot be driven by any
 * test. It is not dead: it is what protects a Lead loaded before the flow existed, and what would
 * protect the whole pipeline if the flow were ever deactivated. It is carried by the formula and
 * documented here rather than pretended to be tested.
 *
 * ⚠ THE CONVERSION PATH IS INERT EITHER WAY AND IS NOT TESTED HERE.
 * `Database.convertLead` only enforces Lead validation rules when
 * `shouldLeadConvertRequireValidation` is true; that setting lives in
 * `settings/LeadConfig.settings-meta.xml`, which is `.forceignore`d and is an UNVERIFIED SNAPSHOT
 * (post-deploy gate G6 — verify it in Setup, never in the repo). It does not matter which way it is
 * set: conversion does not change this field, so `ISCHANGED` is false on that path regardless.
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not bite here — there is no
 * trigger, no batch, no queueable and no service under test, only a declarative rule. Bulk
 * behaviour of the Lead object itself is covered by `LeadSelectorTest` at 251.
 */
@isTest
private class LeadFirstSeenValidationTest {

    /** Insert past the org's live Lead duplicate rule — the `LeadSelectorTest` helper's shape. */
    private static void insertWithDupBypass(List<Lead> leads) {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.insert(leads, dml);
    }

    private static Lead insertedLead() {
        List<Lead> leads = TestDataFactory.createLeads(1, false);
        insertWithDupBypass(leads);
        return [SELECT Id, First_Seen_Date__c, Status FROM Lead WHERE Id = :leads[0].Id];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE WRITERS THAT MUST **NOT** BE BLOCKED
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void insertingALeadWithAnExplicitFirstSeenDateIsAllowed() {
        // 🔴 `ISCHANGED` IS FALSE ON INSERT, AND THAT IS A DELIBERATE HOLE, NOT AN OVERSIGHT — the
        // same hole the deployed NDA rule carries and states. It is what keeps every legitimate
        // creator working: BrokerPortalService (a guest insert that sets the field itself), the
        // inbound-email pipeline, a data load, and a human keying a Lead by hand.
        DateTime supplied = DateTime.now().addDays(-14);
        List<Lead> leads = TestDataFactory.createLeads(1, false);
        leads[0].First_Seen_Date__c = supplied;

        Test.startTest();
        insertWithDupBypass(leads);
        Test.stopTest();

        Lead stored = [SELECT First_Seen_Date__c FROM Lead WHERE Id = :leads[0].Id];
        Assert.areEqual(supplied, stored.First_Seen_Date__c,
            'A supplied first-seen date survives insert untouched — the rule must never fire on '
            + 'create, or the Broker Portal and the email pipeline both stop working');
    }

    @isTest
    static void theIntakeFlowsOwnStampAtInsertIsNeverBlocked() {
        // `Lead_Intake_Stamp` is a BEFORE-SAVE flow, so its assignment happens before validation
        // rules run. If this insert ever fails, the rule has been widened to cover create and the
        // entire Lead intake pipeline is down.
        Test.startTest();
        Lead stored = insertedLead();
        Test.stopTest();

        Assert.isNotNull(stored.First_Seen_Date__c,
            'Lead_Intake_Stamp stamps a blank First Seen Date at insert, and the rule must not '
            + 'block it — the blank-prior clause exempts it, and ISCHANGED is false on insert '
            + 'anyway, so it is exempt twice over');
    }

    @isTest
    static void anOrdinaryLeadUpdateThatDoesNotTouchTheFieldStillSaves() {
        // 🔴 THE LARGEST REGRESSION SURFACE OF ALL, AND THE CHEAPEST TO PROVE. Every stage quick
        // action, every Broker Protection routing branch and every manual edit updates a Lead
        // without going near this field. A rule missing its ISCHANGED guard would block ALL of
        // them, and nothing else in the suite is aimed at that.
        Lead lead = insertedLead();

        Test.startTest();
        update new Lead(Id = lead.Id, Status = 'Under Review');
        Test.stopTest();

        Assert.areEqual('Under Review',
            [SELECT Status FROM Lead WHERE Id = :lead.Id].Status,
            'An update that leaves First_Seen_Date__c alone must be completely unaffected');
    }

    @isTest
    static void rewritingTheIdenticalValueIsNotAChangeAndIsAllowed() {
        // ISCHANGED compares VALUES, not whether the field appeared in the DML. A Data Loader
        // round-trip that re-submits every column unchanged must not be refused — pinned because
        // an implementation using ISNEW/PRIORVALUE differently would break exactly this shape.
        Lead lead = insertedLead();

        Test.startTest();
        update new Lead(Id = lead.Id, First_Seen_Date__c = lead.First_Seen_Date__c);
        Test.stopTest();

        Assert.areEqual(lead.First_Seen_Date__c,
            [SELECT First_Seen_Date__c FROM Lead WHERE Id = :lead.Id].First_Seen_Date__c,
            'Re-asserting the same value is not a change and is allowed');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 🔴 THE POPULATION THE RULE EXISTS FOR
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void changingAnAlreadyStampedFirstSeenDateIsRefused() {
        Lead lead = insertedLead();
        Assert.isNotNull(lead.First_Seen_Date__c,
            'PRECONDITION: the flow stamped it, so the prior value is non-blank');

        Test.startTest();
        String message = null;
        try {
            update new Lead(Id = lead.Id, First_Seen_Date__c = DateTime.now().addDays(-400));
            Assert.fail('Back-dating an already-stamped first-seen date must be REFUSED. This is '
                + 'the whole point of the rule: First_Seen_Date__c anchors BP_Expiry__c, so moving '
                + 'it back 400 days silently extends a broker\'s 90-day protection window by more '
                + 'than a year.');
        } catch (DmlException e) {
            message = e.getDmlMessage(0);
        }
        Test.stopTest();

        Assert.isNotNull(message, 'The refusal is a DmlException carrying the rule\'s own message');
        // ⚠ Asserted on a SUBSTRING, not on the whole string: the error message is user-facing copy
        // an admin may legitimately reword, and pinning it byte-for-byte would make a wording
        // change look like a behaviour regression.
        Assert.isTrue(message.containsIgnoreCase('first seen'),
            'and the message names the field, so the user learns which one — got: ' + message);
    }

    @isTest
    static void clearingAnAlreadyStampedFirstSeenDateIsRefused() {
        // The other half of tampering, and the more dangerous one: BLANKING the field would make
        // BP_Expiry__c null and LeadFunnelController fall back to CreatedDate, silently RESETTING
        // a broker's protection window rather than merely moving it.
        Lead lead = insertedLead();

        Test.startTest();
        Boolean refused = false;
        try {
            update new Lead(Id = lead.Id, First_Seen_Date__c = null);
        } catch (DmlException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused, 'Clearing an already-stamped first-seen date must be REFUSED');
        Assert.isNotNull(
            [SELECT First_Seen_Date__c FROM Lead WHERE Id = :lead.Id].First_Seen_Date__c,
            'and the stored value is untouched');
    }

    @isTest
    static void thereIsDeliberatelyNoAdminBypass() {
        // 🔴 GATE 1 DECISION Q3.1(a): NO BYPASS. The rule is ANTI-TAMPERING, so a bypass re-opens
        // it for exactly the population most able to tamper; a genuine data correction has an
        // auditable path (deactivate the rule, fix, reactivate). This test runs as the suite's
        // running user — an administrator in every practical case — and requires the refusal to
        // hold anyway.
        //
        // ⚠ IF A BYPASS IS EVER ADDED IT MUST BE A CUSTOM PERMISSION, NEVER A FIELD REFERENCE. A
        // rule bound to a field evaluates FALSE for anyone lacking FLS on it, silently — that is
        // the measured defect that retired the `User.*_Driver__c` model org-wide on 2026-08-12.
        Lead lead = insertedLead();

        Test.startTest();
        Boolean refused = false;
        try {
            update new Lead(Id = lead.Id, First_Seen_Date__c = DateTime.now().addYears(-2));
        } catch (DmlException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused,
            'The refusal holds for the running user with no exemption of any kind');
    }
}
