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
 * ⚠ WHERE 251 NOW LIVES (updated 2026-08-02). The waiver above covers convert()
 * ONLY, and it narrowed when Smart Lead Conversion added a read step. convert() now
 * delegates matching to LeadConvertMatchService.matchForConversion, which performs
 * NO DML and NO convertLead — so the platform ceiling that justifies this waiver does
 * not apply to it, and it carries a real 251-record bulk test:
 * LeadConvertMatchServiceTest.matchForConversion_at251Leads_isBulkSafe, which also
 * asserts the SOQL delta against a <= 3 budget. Do not read this waiver as covering
 * the matching path.
 *
 * ── SMART CONVERSION (attach to existing Contact / Account), added 2026-08-02 ──
 * The four tests at the bottom of this class cover the behaviour introduced by the
 * 2026-08-02 DUPLICATES_DETECTED incident: attaching instead of duplicating (which also
 * carries the V3 Opportunity-Name OBSERVATION — see that test's own comment; it cannot
 * false-fail and is not a naming requirement), the D4 duplicate-rule bypass, the E1
 * anchor-Task check, and the V2 no-overwrite check.
 * Every OTHER test in this class stays on the NO-MATCH path and is unchanged —
 * verified, not assumed: TestDataFactory.createLeads generates
 * Email = 'test.lead<u>@example.invalid' and Company = 'Test Company <i>-<u>', both
 * unique per record, and createContacts generates 'test.contact<u>@example.invalid',
 * so no factory Lead can ever email-match a factory Contact or name-match a factory
 * Account ('Test Account <i>-<u>').
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

    /**
     * The Account.Broker_Firm / Contact.Broker record type Ids, resolved via describe — IR
     * segregation (2026-08-10, Task 6). The four SMART CONVERSION fixtures below build a
     * pre-existing Contact/Account by hand (not via TestDataFactory, which auto-stamps these)
     * specifically so `LeadConvertMatchService` (via `ContactSelector.selectByEmails` /
     * `AccountSelector.selectByNames`) can find and attach to them; both selectors are now scoped
     * to the Broker / Broker_Firm record types, so an unstamped fixture would silently stop
     * matching and each "attaches instead of duplicating" assertion below would fail for the
     * wrong reason (record-type mismatch, not a real regression in the attach logic).
     */
    private static Id brokerFirmRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Broker_Firm').getRecordTypeId();
    }

    private static Id brokerRecordTypeId() {
        return Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName().get('Broker').getRecordTypeId();
    }

    @isTest
    static void convert_singleLead_returnsOpportunityIdAndRunsFullConversionPipeline() {
        // Arrange
        Lead l = buildConvertibleLead('Retail', 'Single Convert LLC');
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
        Assert.areEqual('Retail', opp.Deal_Type__c, 'Deal Type should carry from the Lead to the Opportunity');
        Assert.areEqual('Retail', opp.RecordType.DeveloperName, 'The matching Retail record type should apply');
        Assert.areEqual(UserInfo.getUserId(), opp.Lead_Approved_By__c,
            'The converting user should be stamped as Lead Approved By');
    }

    @isTest
    static void convert_smallList_returnsIndexAlignedOpportunityIds() {
        // Arrange — 3 Leads (comfortably under any per-call ceiling), mixed deal types.
        Lead land = buildConvertibleLead('Land', 'Land Small List LLC');
        Lead commercial = buildConvertibleLead('Retail', 'Commercial Small List LLC');
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

    // ═════════════════════════════════════════════════════════════════════════════
    // SMART CONVERSION — attach to existing records (2026-08-02)
    // ═════════════════════════════════════════════════════════════════════════════

    /**
     * THE INCIDENT, FIXED. A repeat broker already exists as a Contact under their firm's
     * Account. Converting their new Lead must ATTACH to both and create ONLY the Opportunity
     * (plus the module's usual Property__c) — no second Contact, no second Account.
     *
     * The total-count assertions are the load-bearing ones: asserting only that
     * ConvertedContactId points at the existing Contact would still pass if the conversion
     * ALSO minted a stray Account, which is half the bug.
     *
     * Also re-asserts the post-convert cascade artifacts here rather than trusting the
     * isolated cascade tests: attaching changes what conversion creates, so this is the place
     * a silent regression in LeadConvertService's stamping would show up.
     */
    @isTest
    static void convert_existingContactAndAccount_attachesInsteadOfCreatingDuplicates() {
        // Arrange — the broker's existing firm + Contact.
        Account firm = new Account(Name = 'Repeat Broker Firm LLC', BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());
        insert firm;
        Contact broker = new Contact(
            FirstName = 'Repeat', LastName = 'Broker',
            Email = 'repeat.broker@firm.invalid', AccountId = firm.Id,
            RecordTypeId = brokerRecordTypeId()
        );
        insert broker;

        Lead l = buildConvertibleLead('Retail', 'Some Company The LLM Extracted');
        l.Email = 'repeat.broker@firm.invalid';
        insert l;

        Integer accountsBefore = [SELECT COUNT() FROM Account];
        Integer contactsBefore = [SELECT COUNT() FROM Contact];

        // Act
        Test.startTest();
        List<Id> opportunityIds = LeadConvertActionService.convert(new List<Id>{ l.Id });
        Test.stopTest();

        // Assert — attached, not duplicated
        Assert.areEqual(accountsBefore, [SELECT COUNT() FROM Account],
            'Attaching to an existing Account must create NO new Account');
        Assert.areEqual(contactsBefore, [SELECT COUNT() FROM Contact],
            'Attaching to an existing Contact must create NO new Contact');

        Lead converted = [
            SELECT IsConverted, ConvertedContactId, ConvertedAccountId, ConvertedOpportunityId
            FROM Lead WHERE Id = :l.Id
        ];
        Assert.isTrue(converted.IsConverted, 'The Lead should be converted');
        Assert.areEqual(broker.Id, converted.ConvertedContactId,
            'Conversion should target the broker\'s EXISTING Contact');
        Assert.areEqual(firm.Id, converted.ConvertedAccountId,
            'Conversion should target the matched Contact\'s OWN Account');

        // Assert — the Opportunity IS still created, and the post-convert cascade still ran
        Assert.areEqual(1, opportunityIds.size(), 'One Lead should still produce one Opportunity');
        Assert.areEqual(converted.ConvertedOpportunityId, opportunityIds[0],
            'The returned Id should be the Lead\'s actual ConvertedOpportunityId');
        Opportunity opp = [
            SELECT Name, AccountId, Property__c, Deal_Type__c, RecordType.DeveloperName, Lead_Approved_By__c
            FROM Opportunity WHERE Id = :opportunityIds[0]
        ];
        Assert.areEqual(firm.Id, opp.AccountId, 'The new Opportunity should sit under the existing firm Account');
        Assert.isNotNull(opp.Property__c, 'The conversion cascade must still create and link a Property');
        Assert.areEqual('Retail', opp.Deal_Type__c, 'Deal Type must still carry from the Lead');
        Assert.areEqual('Retail', opp.RecordType.DeveloperName, 'The Retail record type must still apply');
        Assert.areEqual(UserInfo.getUserId(), opp.Lead_Approved_By__c,
            'Lead Approved By must still be stamped by the cascade');

        // V3 (design §9) — OBSERVATION ONLY, deliberately constructed so it cannot false-fail.
        // What the platform names the Opportunity when converting into an EXISTING Account (as
        // opposed to a newly-created one) is not documented anywhere and is intentionally left to
        // standard conversion (no setOpportunityName call — design §8 scope guard). Name is a
        // required field, so a non-null check is trivially true for any successfully created row
        // regardless of what convention the platform actually applies; the debug line is what
        // surfaces the OBSERVED value for a human to read off a real test/deploy run and record as
        // a baseline. Do not tighten this into an exact-value assertion without first confirming
        // the convention against a live org — a guess here would only ever be wrong once and be a
        // false failure, not a real regression.
        System.debug(LoggingLevel.INFO, 'V3 OBSERVATION — Opportunity.Name when converting into an '
            + 'EXISTING Account: "' + opp.Name + '" (Lead.Company was "' + l.Company + '", existing '
            + 'Account.Name was "' + firm.Name + '"). Record this as the baseline convention; a future '
            + 'shift is not a regression unless this comment is promoted to a real assertion.');
        Assert.isNotNull(opp.Name, 'V3: the created Opportunity must have SOME Name (a required field) '
            + '— see the debug log above for the actual observed value');
    }

    /**
     * D4 — CONVERSION PROCEEDS WITH THE DUPLICATE RULES ACTIVE.
     *
     * The fixture is the residual case the bypass actually covers: a FUZZY near-duplicate —
     * same first/last name and phone, but a DIFFERENT email — so exact email matching
     * deliberately MISSES and conversion must create a second Contact. Before the bypass this
     * is the shape that produced `DUPLICATES_DETECTED, Duplicate Alert: []`.
     *
     * ⚠ THIS IS A SMOKE TEST, AND ITS AUTHORITY LIVES ELSEWHERE. The standard match rules'
     * criteria are not in source control, so this test cannot and does not prove the rule
     * fired. All it asserts is the CONTRACT: conversion SUCCEEDS with the org's duplicate rules
     * active. The CAUSAL proof that the bypass is what makes it succeed was taken at build time
     * (design V1) on DPEG-Acq-5 with both standard rules confirmed active: one identical fixture
     * was BLOCKED without the setters and SUCCEEDED with them. This test is the standing
     * regression guard for that result, and the deploy-time proof on usman-dpeg where the same
     * rules are active.
     *
     * ⚠ DO NOT "STRENGTHEN" THIS INTO ASSERTING THAT THE RULE FIRED (e.g. by asserting a
     * DuplicateRecordSet, or that removing the bypass blocks). Doing so couples the test to the
     * org's UNDOCUMENTED standard fuzzy matching criteria, which are not in source control, can
     * be changed in Setup by anyone, and differ between orgs — the test would go intermittently
     * red for reasons that have nothing to do with this code. A weaker assertion that is always
     * true when the code is correct beats a stronger one that is sometimes false when it is.
     */
    @isTest
    static void convert_nearDuplicateContactWithRulesActive_stillSucceeds() {
        Account firm = new Account(Name = 'Near Duplicate Firm', BillingCity = 'Houston', BillingState = 'TX');
        insert firm;
        Contact existing = new Contact(
            FirstName = 'Nearly', LastName = 'Duplicate',
            Email = 'nearly.duplicate.original@firm.invalid',
            Phone = '281-555-0199', Title = 'Broker',
            MailingStreet = '900 Duplicate Way', MailingCity = 'Houston',
            AccountId = firm.Id
        );
        insert existing;

        // Same person by every fuzzy criterion, different email => our exact match misses.
        Lead l = buildConvertibleLead('Retail', 'Near Duplicate Co');
        l.FirstName = 'Nearly';
        l.LastName = 'Duplicate';
        l.Email = 'nearly.duplicate.different@firm.invalid';
        l.Phone = '281-555-0199';
        l.Title = 'Broker';
        l.Street = '900 Duplicate Way';
        l.City = 'Houston';
        insert l;

        Test.startTest();
        List<Id> opportunityIds = LeadConvertActionService.convert(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.areEqual(1, opportunityIds.size(),
            'Conversion must SUCCEED with the duplicate rules active — a block here is the incident regressing');
        Assert.isNotNull(opportunityIds[0], 'The conversion should have produced an Opportunity');

        Lead converted = [SELECT IsConverted, ConvertedContactId FROM Lead WHERE Id = :l.Id];
        Assert.isTrue(converted.IsConverted, 'The Lead should be converted');
        Assert.areNotEqual(existing.Id, converted.ConvertedContactId,
            'A different email is deliberately NOT a match — a new Contact is the correct, recoverable outcome');
        Assert.areEqual(2, [SELECT COUNT() FROM Contact WHERE LastName = 'Duplicate'],
            'The near-duplicate Contact should have been created rather than blocking the conversion');
    }

    /**
     * §7.7 / E1 — THE ANCHOR CHECK. The EAC Thread Guard decides what to delete purely by
     * matching thread anchors that the Broker Protection pipeline logged as Tasks. If
     * conversion stopped carrying those anchors onto the converted records, the guard would be
     * silently disarmed.
     *
     * E1 already measured this against a CONVERSION-CREATED Contact. This asserts the same
     * holds when the Contact PRE-EXISTED — the new case this feature introduces — which is the
     * whole reason the check is repeated here.
     *
     * The Task mirrors a real pipeline anchor exactly (Status Completed, TaskSubtype 'Email',
     * both threading keys). Task.Type is deliberately never set: it does not exist in this
     * org's template, compiles anyway, and throws at runtime.
     */
    @isTest
    static void convert_attachingToExistingContact_repointsTheAnchorTask() {
        Account firm = new Account(Name = 'Anchor Firm LLC', BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());
        insert firm;
        Contact broker = new Contact(
            FirstName = 'Anchor', LastName = 'Broker',
            Email = 'anchor.broker@firm.invalid', AccountId = firm.Id,
            RecordTypeId = brokerRecordTypeId()
        );
        insert broker;

        Lead l = buildConvertibleLead('Retail', 'Anchor Test Co');
        l.Email = 'anchor.broker@firm.invalid';
        insert l;

        Task anchor = new Task(
            Subject = 'FW: 1234 Main St offering',
            Description = 'inbound broker email body',
            ActivityDate = Date.today(),
            Status = 'Completed',
            TaskSubtype = 'Email',
            WhoId = l.Id,
            Inbound_Message_Id__c = '<anchor-msg-001@broker.invalid>',
            Thread_Key__c = '<anchor-thread-001@broker.invalid>'
        );
        insert anchor;

        Test.startTest();
        List<Id> opportunityIds = LeadConvertActionService.convert(new List<Id>{ l.Id });
        Test.stopTest();

        Task afterConvert = [
            SELECT WhoId, WhatId, Inbound_Message_Id__c, Thread_Key__c FROM Task WHERE Id = :anchor.Id
        ];
        Assert.areEqual(broker.Id, afterConvert.WhoId,
            'The anchor Task must follow onto the PRE-EXISTING Contact — the EAC Thread Guard matches on it');
        Assert.areEqual(opportunityIds[0], afterConvert.WhatId,
            'The anchor Task should point at the new Opportunity. Observed WhatId = '
            + afterConvert.WhatId + ' (a 001 prefix would mean the Account, not the Opportunity)');
        Assert.areEqual('<anchor-msg-001@broker.invalid>', afterConvert.Inbound_Message_Id__c,
            'The idempotency anchor must survive conversion unchanged');
        Assert.areEqual('<anchor-thread-001@broker.invalid>', afterConvert.Thread_Key__c,
            'The conversation-root anchor must survive conversion unchanged');
    }

    /**
     * V2 — ATTACHING MUST NOT OVERWRITE THE EXISTING RECORDS. Expected platform behaviour, but
     * cheap to check and high blast radius: the Lead's person fields are LLM-extracted from a
     * forwarded signature block, so if conversion pushed them onto the matched Contact it would
     * overwrite good CRM data with a guess. Every Lead value below deliberately differs from
     * the Contact/Account it attaches to.
     */
    @isTest
    static void convert_attachingToExistingContact_doesNotOverwriteExistingFieldValues() {
        Account firm = new Account(Name = 'Pristine Firm LLC', BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());
        insert firm;
        Contact broker = new Contact(
            FirstName = 'Pristine', LastName = 'Broker',
            Email = 'pristine.broker@firm.invalid',
            Title = 'Managing Director', Phone = '713-555-0100',
            AccountId = firm.Id,
            RecordTypeId = brokerRecordTypeId()
        );
        insert broker;

        Lead l = buildConvertibleLead('Retail', 'Wrong Company Name From LLM');
        l.FirstName = 'Mis';                       // differs
        l.LastName = 'Extracted';                  // differs
        l.Email = 'pristine.broker@firm.invalid';  // the only thing that matches
        l.Title = 'Junior Associate';              // differs
        l.Phone = '999-555-9999';                  // differs
        insert l;

        Test.startTest();
        LeadConvertActionService.convert(new List<Id>{ l.Id });
        Test.stopTest();

        Contact afterConvert = [
            SELECT FirstName, LastName, Title, Phone, Email, AccountId FROM Contact WHERE Id = :broker.Id
        ];
        Assert.areEqual('Pristine', afterConvert.FirstName, 'The existing Contact\'s FirstName must not be overwritten');
        Assert.areEqual('Broker', afterConvert.LastName, 'The existing Contact\'s LastName must not be overwritten');
        Assert.areEqual('Managing Director', afterConvert.Title, 'The existing Contact\'s Title must not be overwritten');
        Assert.areEqual('713-555-0100', afterConvert.Phone, 'The existing Contact\'s Phone must not be overwritten');
        Assert.areEqual(firm.Id, afterConvert.AccountId, 'The existing Contact must stay under its own Account');

        Account firmAfter = [SELECT Name FROM Account WHERE Id = :firm.Id];
        Assert.areEqual('Pristine Firm LLC', firmAfter.Name,
            'The existing Account\'s Name must not be overwritten by the Lead\'s Company');
    }
}
