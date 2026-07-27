/**
 * Tests LeadConvertActionService — the sole class in the app that runs
 * Database.convertLead. Every scenario below drives a REAL Database.convertLead
 * call through the service (Database.convertLead cannot be mocked), so the full
 * conversion pipeline — including the same-transaction LeadConvertTrigger ->
 * LeadConvertService cascade that creates the Property__c and stamps the
 * Opportunity (Deal Type, record type, Lead Approved By) — is proven end to end,
 * exactly as LeadConvertServiceTest / LeadConvertTriggerHandlerTest already prove
 * for that cascade in isolation.
 *
 * setDoNotCreateOpportunity(true) is never used anywhere in this class. The
 * service under test always leaves it at its own default (false) — passing
 * true is documented (LeadConvertActionService class header) to throw
 * UNKNOWN_EXCEPTION on this org.
 *
 * ── WHY THIS CLASS HAS NO 251-RECORD convert() TEST (.claude/rules/bulk-test-rule.md) ──
 * LeadConvertActionService.convert() deliberately builds every input Id into ONE
 * un-chunked Database.convertLead call (see its class header: "Single all-or-none
 * conversion call... no conversion (and no DML) inside a loop"). Per this
 * feature's build notes, Database.convertLead enforces a hard per-call ceiling
 * well under 251 successful conversions in this org (~100) — unlike
 * LeadConvertServiceTest.bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities
 * and LeadConvertTriggerHandlerTest.bulk251ConversionsStampEveryOpportunity, which
 * only reach 251 because they manually split the Leads into two separate calls
 * (200 + 51) before ever calling Database.convertLead. LeadConvertActionService
 * has no such chunking — one call is its contract — so a 251-record call here
 * would fail against the platform's own per-call ceiling before exercising any
 * of the service's own logic, proving nothing about convert()'s correctness.
 * This mirrors the documented per-transaction exemption pattern already in
 * bulk-test-rule.md (the Broker Protection async-pipeline exemption): the
 * 251-record volume requirement is waived because the code path is
 * architecturally incapable of processing that volume in a single call, not
 * because it was left untested. Instead, convert()'s collection handling and
 * index-alignment are proven with a small (3-Lead) list — comfortably under any
 * plausible per-call ceiling — plus the null/empty-input guard and a real
 * DmlException propagation path.
 *
 * @see force-app/main/default/classes/LeadConvertActionService.cls
 * @see force-app/main/default/classes/LeadConvertServiceTest.cls (cascade proven in isolation)
 * @see force-app/main/default/classes/LeadConvertTriggerHandlerTest.cls (251-lead chunked bulk proof)
 * @see .claude/rules/bulk-test-rule.md
 */
@isTest
private class LeadConvertActionServiceTest {

    /**
     * A convertible Lead: TestDataFactory.createLead already sets LastName, Company,
     * Deal_Type__c, Asset_Type__c, Property_Address__c, Guidance_Price__c, and
     * Guidance_Cap_Rate__c — exactly the fields LeadConvertService reads to build the
     * Property and stamp the Opportunity, so no factory changes were needed for this test.
     */
    private static Lead buildConvertibleLead(String dealType, String company) {
        Lead l = TestDataFactory.createLead(false);
        l.Company = company;
        l.Deal_Type__c = dealType;
        return l;
    }

    @isTest
    static void convert_singleLead_returnsOpportunityIdAndRunsFullConversionPipeline() {
        // Arrange
        Lead l = buildConvertibleLead('Commercial', 'Single Convert LLC');
        insert l;

        // Act
        Test.startTest();
        List<Id> opportunityIds = LeadConvertActionService.convert(new List<Id>{ l.Id });
        Test.stopTest();

        // Assert — the direct return contract
        Assert.areEqual(1, opportunityIds.size(), 'One input Lead should produce exactly one Opportunity Id');
        Assert.isNotNull(opportunityIds[0], 'The returned Opportunity Id should not be null');

        // Assert — the Lead actually converted to that same Opportunity
        Lead converted = [SELECT IsConverted, ConvertedOpportunityId FROM Lead WHERE Id = :l.Id];
        Assert.isTrue(converted.IsConverted, 'The Lead should be converted');
        Assert.areEqual(opportunityIds[0], converted.ConvertedOpportunityId,
            'The returned Id should be the Lead\'s actual ConvertedOpportunityId');

        // Assert — the same-transaction LeadConvertTrigger -> LeadConvertService cascade ran
        Opportunity opp = [
            SELECT Property__c, Deal_Type__c, RecordType.DeveloperName, Lead_Approved_By__c
            FROM Opportunity WHERE Id = :opportunityIds[0]
        ];
        Assert.isNotNull(opp.Property__c, 'The conversion cascade should create and link a Property');
        Assert.areEqual('Commercial', opp.Deal_Type__c, 'Deal Type should carry from the Lead to the Opportunity');
        Assert.areEqual('Commercial', opp.RecordType.DeveloperName, 'The matching Commercial record type should apply');
        Assert.areEqual(UserInfo.getUserId(), opp.Lead_Approved_By__c,
            'The converting user should be stamped as Lead Approved By');
    }

    @isTest
    static void convert_smallList_returnsIndexAlignedOpportunityIds() {
        // Arrange — 3 Leads (comfortably under any per-call ceiling), mixed deal types.
        Lead land = buildConvertibleLead('Land', 'Land Small List LLC');
        Lead commercial = buildConvertibleLead('Commercial', 'Commercial Small List LLC');
        Lead land2 = buildConvertibleLead('Land', 'Land Small List Two LLC');
        insert new List<Lead>{ land, commercial, land2 };
        List<Id> leadIds = new List<Id>{ land.Id, commercial.Id, land2.Id };

        // Act
        Test.startTest();
        List<Id> opportunityIds = LeadConvertActionService.convert(leadIds);
        Test.stopTest();

        // Assert — one Opportunity Id per input Lead, none null, all distinct
        Assert.areEqual(3, opportunityIds.size(), 'Three input Leads should produce three Opportunity Ids');
        Set<Id> distinctOppIds = new Set<Id>();
        for (Id oppId : opportunityIds) {
            Assert.isNotNull(oppId, 'Every returned Opportunity Id should be populated');
            distinctOppIds.add(oppId);
        }
        Assert.areEqual(3, distinctOppIds.size(), 'Each Lead should convert to its own distinct Opportunity');

        // Assert — index alignment: opportunityIds[i] must be leadIds[i]'s ConvertedOpportunityId
        Map<Id, Id> leadIdToConvertedOppId = new Map<Id, Id>();
        for (Lead convertedLead : [
            SELECT Id, ConvertedOpportunityId FROM Lead WHERE Id IN :leadIds
        ]) {
            leadIdToConvertedOppId.put(convertedLead.Id, convertedLead.ConvertedOpportunityId);
        }
        for (Integer i = 0; i < leadIds.size(); i++) {
            Assert.areEqual(leadIdToConvertedOppId.get(leadIds[i]), opportunityIds[i],
                'opportunityIds[' + i + '] should be the Opportunity Id actually created for leadIds[' + i + ']');
        }
    }

    @isTest
    static void convert_nullInput_returnsEmptyList() {
        // Act
        Test.startTest();
        List<Id> result = LeadConvertActionService.convert(null);
        Test.stopTest();

        // Assert
        Assert.isNotNull(result, 'A null input should still return a list, not null');
        Assert.isTrue(result.isEmpty(), 'A null input should return an empty list');
    }

    @isTest
    static void convert_emptyInput_returnsEmptyList() {
        // Act
        Test.startTest();
        List<Id> result = LeadConvertActionService.convert(new List<Id>());
        Test.stopTest();

        // Assert
        Assert.isNotNull(result, 'An empty input should still return a list, not null');
        Assert.isTrue(result.isEmpty(), 'An empty input should return an empty list');
    }

    @isTest
    static void convert_alreadyConvertedLead_throwsDmlException() {
        // Arrange — convert once so the Lead is already converted.
        Lead l = buildConvertibleLead('Land', 'Already Converted LLC');
        insert l;
        LeadConvertActionService.convert(new List<Id>{ l.Id });

        // Act & Assert — converting the same (now-converted) Lead again must fail, and the
        // DmlException must propagate uncaught out of convert() for the controller to wrap.
        Test.startTest();
        try {
            LeadConvertActionService.convert(new List<Id>{ l.Id });
            Assert.fail('Expected a DmlException when converting an already-converted Lead');
        } catch (DmlException e) {
            Assert.isTrue(String.isNotBlank(e.getMessage()),
                'The DmlException should carry a message describing why the second conversion failed');
        }
        Test.stopTest();
    }
}
