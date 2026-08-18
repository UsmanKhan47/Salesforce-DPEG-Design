@isTest
private class LeadFunnelControllerTest {
    @testSetup
    static void setup() {
        List<Lead> leads = TestDataFactory.createLeads(3, false);

        leads[0].LeadSource = 'Email-to-Lead';
        leads[0].Parse_Confidence__c = 'HIGH';
        leads[0].Guidance_Price__c = 18800000;
        leads[0].Broker_First__c = 'CBRE';
        leads[0].Property_Address__c = 'Hwy 290 Retail';
        leads[0].Asset_Type__c = 'Retail';
        leads[0].First_Seen_Date__c = Datetime.now().addDays(-10);
        // ⚠ EXTRACTION SCORE (2026-08-17) — SET ON TWO OF THE THREE, LEFT NULL ON THE THIRD ON
        // PURPOSE. It is a DIFFERENT fact from Parse_Confidence__c (completeness of the extraction vs
        // certainty about is_acquisition_related), and null means "not scored", never zero — so the
        // fixture must carry a scored HIGH-confidence lead, a scored LOW-confidence one and an
        // unscored one, or getFunnel_leadRowCarriesTheExtractionScore could not tell the two facts
        // apart or prove the null passes through.
        leads[0].Extraction_Score_Pct__c = 89;

        leads[1].LeadSource = 'Broker Portal';
        leads[1].Parse_Confidence__c = 'LOW';
        leads[1].Guidance_Price__c = 9400000;
        leads[1].Broker_First__c = 'Marcus & Millichap';
        leads[1].Property_Address__c = 'Mills Outparcel';
        leads[1].Asset_Type__c = 'Retail';
        leads[1].First_Seen_Date__c = Datetime.now().addDays(-10);
        // LOW confidence but a HIGH score: the combination the field metadata insists is possible, and
        // the reason the two are shown side by side rather than merged.
        leads[1].Extraction_Score_Pct__c = 100;

        // Older lead from a high-priority broker: must surface FIRST despite its age.
        leads[2].LeadSource = 'Manual Entry';
        leads[2].Parse_Confidence__c = 'HIGH';
        leads[2].Guidance_Price__c = 12500000;
        leads[2].Broker_First__c = 'JLL';
        leads[2].Property_Address__c = 'I-35 Strip Center';
        leads[2].Asset_Type__c = 'Retail';
        leads[2].Broker_Priority__c = 'High';
        leads[2].First_Seen_Date__c = Datetime.now().addDays(-20);
        // Deliberately UNSCORED (left null) — the fail-soft state.
        leads[2].Extraction_Score_Pct__c = null;

        insert leads;
    }

    @isTest
    static void testGetFunnel() {
        Test.startTest();
        LeadFunnelController.FunnelData data = LeadFunnelController.getFunnel();
        Test.stopTest();

        System.assertEquals(5, data.stages.size(), 'Five stages expected');
        System.assertEquals(3, data.channels.size(), 'Three channels expected');
        System.assertEquals(3, data.total, 'Three leads seeded');
        System.assertEquals(1, data.reviewQueue, 'One LOW-confidence lead');

        // High-priority broker leads outrank recency.
        LeadFunnelController.LeadRow first = data.recent[0];
        System.assertEquals('I-35 Strip Center', first.name, 'High-priority broker lead surfaces first');
        System.assertEquals('High', first.priority, 'Priority carried to the row');

        // BP window: First Seen 10 days ago -> ~80 days remaining, expiry still active.
        LeadFunnelController.LeadRow row = data.recent[1];
        System.assertEquals(10, row.days, 'Age derived from First Seen Date');
        System.assertEquals(Date.today().addDays(80), row.bpExpiry, 'BP expiry = First Seen + 90');
        System.assertEquals(true, row.bpActive, 'BP window still active');
    }

    // ── P6 boundary coverage ─────────────────────────────────────────────────────
    // A bare Standard User with no DPEG perm sets: LeadSelector.selectRecent selects custom
    // Lead fields (Parse_Confidence__c, Guidance_Price__c, …) the bare user has no FLS on, so
    // WITH USER_MODE throws — exercising getFunnel's read-failure catch (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6lf', Email = 'p6lf@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6LeadFunnel', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6lf.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers the First Seen Date -> CreatedDate fallback: a lead with no First_Seen_Date__c
     * makes getFunnel derive age/BP-window from CreatedDate instead. Isolated in its own
     * method so the seeded three-lead assertions in testGetFunnel are unaffected.
     */
    @isTest
    static void getFunnel_leadWithoutFirstSeenDate_fallsBackToCreatedDate() {
        // Uniquely named/addressed so the org's Lead duplicate rule (which matches live
        // records, including the @testSetup leads, even in tests) does not block the insert.
        String uniq = String.valueOf(DateTime.now().getTime()) + Math.mod(Crypto.getRandomInteger(), 100000);
        String addr = 'No-FirstSeen Parcel ' + uniq;
        Lead l = TestDataFactory.createLeads(1, false)[0];
        l.FirstName = 'NoFS';
        l.LastName = 'NoFirstSeen ' + uniq;
        l.LeadSource = 'Manual Entry';
        l.Parse_Confidence__c = 'HIGH';
        l.Property_Address__c = addr;
        l.First_Seen_Date__c = null;
        insert l;

        Test.startTest();
        LeadFunnelController.FunnelData data = LeadFunnelController.getFunnel();
        Test.stopTest();

        Boolean found = false;
        for (LeadFunnelController.LeadRow r : data.recent) {
            if (r.name == addr) {
                found = true;
                System.assertEquals(Date.today(), r.created, 'Age anchor falls back to CreatedDate when First Seen is null');
                System.assertEquals(0, r.days, 'A lead created today with no First Seen is 0 days old');
                System.assertEquals(Date.today().addDays(90), r.bpExpiry, 'BP expiry derived from the CreatedDate fallback');
            }
        }
        System.assert(found, 'The no-First-Seen lead is present in the funnel');
    }

    /**
     * Covers getFunnel's read-failure catch: under a bare Standard User with no FLS on the
     * custom Lead funnel fields, the WITH USER_MODE recent-leads query throws and the
     * controller maps it to a user-safe AuraHandledException.
     */
    @isTest
    static void getFunnelReadFailureThrowsAuraHandledException() {
        User u = bareUser();
        System.runAs(u) {
            Test.startTest();
            try {
                LeadFunnelController.getFunnel();
                Assert.fail('getFunnel should throw under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getFunnel maps read failure to AuraHandledException');
            }
            Test.stopTest();
        }
    }

    /**
     * The 2026-08-17 addition: `LeadRow.extractionScore` carries `Lead.Extraction_Score_Pct__c`
     * through to `c/recentLeads`' renamed 'Score' column, which renders it BESIDE the confidence band
     * as a second, independently coloured element in one cell.
     *
     * 🔴 IT ASSERTS THE TWO FACTS SEPARATELY, AND THAT IS THE POINT. `Parse_Confidence__c` is the
     * model's certainty about `is_acquisition_related`; `Extraction_Score_Pct__c` is the percent of the
     * nine signed-off deal-process keys captured. The field metadata is explicit that they must never
     * be conflated, so the fixture holds a HIGH-confidence lead scored 89 AND a LOW-confidence lead
     * scored 100 — a row shape that makes "the score is just the confidence in numbers" impossible to
     * believe, and that would red immediately if a future change derived one from the other.
     *
     * ⚠ AND NULL MUST SURVIVE AS NULL. Scoring is fail-soft by mandate (the inbound email pipeline
     * must never be made to throw), so a null reads "not scored" — a state the client renders
     * neutrally. A controller that defaulted it to 0 would tell an analyst the extraction captured
     * none of the nine keys when in truth nothing was measured.
     */
    @isTest
    static void getFunnel_leadRowCarriesTheExtractionScore() {
        Test.startTest();
        LeadFunnelController.FunnelData data = LeadFunnelController.getFunnel();
        Test.stopTest();

        Map<String, LeadFunnelController.LeadRow> byName =
            new Map<String, LeadFunnelController.LeadRow>();
        for (LeadFunnelController.LeadRow r : data.recent) {
            byName.put(r.name, r);
        }

        LeadFunnelController.LeadRow highConf = byName.get('Hwy 290 Retail');
        Assert.isNotNull(highConf, 'Precondition: the HIGH-confidence seeded lead is in the funnel');
        Assert.areEqual('HIGH', highConf.confidence, 'Confidence is carried unchanged');
        // ⚠ `.intValue()` ON A DECIMAL DTO MEMBER, matching PortfolioDealControllerTest's
        // `row.propertyCount.intValue()` precedent: `Assert.areEqual` compares boxed objects, so an
        // Integer literal against a Decimal is a contested comparison in this codebase. Converting
        // sidesteps it, and the field is Number(3,0) so nothing is lost.
        Assert.areEqual(89, highConf.extractionScore.intValue(),
            'extractionScore carries Extraction_Score_Pct__c — a SEPARATE fact from confidence');

        // LOW confidence, PERFECT score. If anything ever derives one from the other, this reds.
        LeadFunnelController.LeadRow lowConf = byName.get('Mills Outparcel');
        Assert.isNotNull(lowConf, 'Precondition: the LOW-confidence seeded lead is in the funnel');
        Assert.areEqual('LOW', lowConf.confidence, 'Confidence is carried unchanged');
        Assert.areEqual(100, lowConf.extractionScore.intValue(),
            'A LOW-confidence email can be COMPLETELY extracted — high confidence does not imply a '
            + 'high score and a low score does not impeach the classification');

        LeadFunnelController.LeadRow unscored = byName.get('I-35 Strip Center');
        Assert.isNotNull(unscored, 'Precondition: the unscored seeded lead is in the funnel');
        Assert.isNull(unscored.extractionScore,
            'An unscored lead arrives as NULL, never 0 — scoring is fail-soft and "not scored" is not '
            + 'the same fact as "captured none of the nine keys"');
    }

    // ── PROPERTY PACKAGE (2026-08-17) — packageId/packageName REMOVED from LeadRow ──────
    //
    // ⚠ SUPERSEDED THE SAME DAY THEY LANDED. Two tests stood here —
    // getFunnel_leadWithPackage_populatesPackageIdAndPackageName and
    // getFunnel_leadWithNoPackage_leavesPackageFieldsNull — pinning that a Lead WITH a package
    // carried both values and that the single-property majority carried neither, so recentLeads
    // could render an empty cell rather than a dead link. Both members are gone: recentLeads'
    // 'Package' column was retired in favour of the c/recentPortfolioDeals card, which reads
    // Portfolio_Deal__c directly instead of inheriting getFunnel's priority partitioning and the
    // client's 5-row cutoff. Those two tests could not survive the removal — they reference fields
    // that no longer compile — so the one below replaces them.
    //
    // 🔴 IT ASSERTS THE ABSENCE, WHICH IS THE HALF THAT ACTUALLY NEEDS PINNING. Deleting the two
    // outright would have left nothing red if a future change re-added the members, and an
    // @AuraEnabled member no client reads is not untidiness here: every one costs a field in
    // LeadSelector.selectRecent's WITH USER_MODE SELECT, which throws on the WHOLE ROW for ONE
    // inaccessible field — i.e. a live way for the entire Lead Funnel homepage to fail for a persona
    // in exchange for nothing on screen.

    @isTest
    static void getFunnel_leadRowCarriesNoPackageMembers() {
        // A Lead that genuinely HAS a package, so this cannot pass merely because the fixture has
        // nothing to report. Under the retired design this row would have carried both values.
        Portfolio_Deal__c pkg = new Portfolio_Deal__c(
            Name = 'FW: funnel package', Property_Count__c = 2);
        insert pkg;

        String uniq = String.valueOf(DateTime.now().getTime()) + Math.mod(Crypto.getRandomInteger(), 100000);
        String addr = 'Packaged Parcel ' + uniq;
        Lead l = TestDataFactory.createLeads(1, false)[0];
        l.LastName = 'PackagedLead ' + uniq;
        l.LeadSource = 'Email-to-Lead';
        l.Parse_Confidence__c = 'HIGH';
        l.Property_Address__c = addr;
        l.Portfolio_Deal__c = pkg.Id;
        insert l;

        Test.startTest();
        LeadFunnelController.FunnelData data = LeadFunnelController.getFunnel();
        Test.stopTest();

        LeadFunnelController.LeadRow packaged = null;
        for (LeadFunnelController.LeadRow r : data.recent) {
            if (r.name == addr) {
                packaged = r;
            }
        }
        Assert.isNotNull(packaged, 'Precondition: the packaged lead is still present in the funnel');

        // Serializing is what the LWC actually receives, so this measures the DTO the client sees
        // rather than the names of Apex properties.
        //
        // ⚠ SINGLE-ARGUMENT JSON.serialize DOES NOT SUPPRESS NULLS — a member that existed but was
        // null would still emit its key, which is precisely what makes containsKey a real falsifier
        // here. Do NOT "improve" this to the two-argument JSON.serialize(obj, true) form
        // (suppressApexObjectNulls): that would make these assertions pass on a null-valued member
        // and the test would stop detecting a re-added field.
        Map<String, Object> wire =
            (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(packaged));

        Assert.isFalse(wire.containsKey('packageId'),
            'LeadRow must not carry packageId — recentLeads has no Package column to read it, and '
            + 'the member would put Lead.Portfolio_Deal__c back in selectRecent\'s USER_MODE '
            + 'SELECT, where one missing FLS grant throws the whole Lead Funnel homepage');
        Assert.isFalse(wire.containsKey('packageName'),
            'LeadRow must not carry packageName — it arrived via the spanning '
            + 'Portfolio_Deal__r.Name, which selectRecent no longer selects');
    }
}
