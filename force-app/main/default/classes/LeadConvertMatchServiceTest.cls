/**
 * Tests LeadConvertMatchService — the class that decides what a lead conversion attaches to.
 *
 * These are UNIT tests of the decision itself: matchForConversion is read-only, so almost every
 * method below asserts the returned map rather than converting anything. The two exceptions are
 * deliberate and named: placeholderCompany_doesNotBucketUnrelatedBrokers drives a real conversion
 * because the decision it pins is only observable as "how many Accounts exist afterwards", and the
 * end-to-end attach behaviour is proven in LeadConvertActionServiceTest.
 *
 * ── WHY 251 BELONGS HERE (.claude/rules/bulk-test-rule.md) ────────────────────────────────
 * LeadConvertActionServiceTest carries a documented waiver from the 251-record mandate, because
 * Database.convertLead enforces a per-call ceiling well under 251 in this org and convert() makes
 * one un-chunked call by contract. THAT WAIVER DOES NOT EXTEND TO THIS CLASS.
 * matchForConversion performs no DML and no convertLead — it is pure read + map-build — so 251 is
 * both reachable and meaningful, and matchForConversion_at251Leads_isBulkSafe below is the
 * highest-value test in this suite: it asserts the SOQL delta against a named budget (<= 3), so a
 * future change that adds one query per Lead fails HERE rather than in production. The measurement
 * is valid taken plainly (this is synchronous code); the bulk-test-rule caveat about
 * Test.stopTest() restoring pre-test counters applies to ASYNC contexts and not to this call.
 *
 * @see force-app/main/default/classes/LeadConvertMatchService.cls
 * @see force-app/main/default/classes/LeadConvertActionServiceTest.cls (end-to-end attach proof)
 * @see agent-output/design-requirements-lead-convert-matching.md (§7)
 */
@isTest
private class LeadConvertMatchServiceTest {

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Fixtures
    // ─────────────────────────────────────────────────────────────────────────────────────

    /** A convertible Lead with the two match keys under test set explicitly. */
    private static Lead buildLead(String email, String company) {
        Lead l = TestDataFactory.createLead(false);
        l.Email = email;
        l.Company = company;
        return l;
    }

    /**
     * An Account with an exact, controlled Name (the factory's names are deliberately unique).
     *
     * ⚠ STAMPED Account.Broker_Firm (2026-08-10, IR segregation, Task 6). AccountSelector.
     * selectByNames — the query this whole suite is testing — is now scoped to
     * RecordType.DeveloperName = 'Broker_Firm'; an unstamped (Master) Account would silently
     * stop matching and every "does/does not match" assertion below would be testing the wrong
     * thing (record-type mismatch, not the D1/D2 decision logic this suite exists to pin).
     */
    private static Account buildFirm(String name) {
        return new Account(Name = name, BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());
    }

    /**
     * A Contact carrying a controlled Email, optionally orphaned (accountId = null).
     *
     * ⚠ STAMPED Contact.Broker (2026-08-10, IR segregation, Task 6) — same reasoning as
     * buildFirm above, for ContactSelector.selectByEmails.
     */
    private static Contact buildBroker(String email, Id accountId) {
        return new Contact(FirstName = 'Broker', LastName = 'Person', Email = email, AccountId = accountId,
            RecordTypeId = brokerRecordTypeId());
    }

    private static Id brokerFirmRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Broker_Firm').getRecordTypeId();
    }

    private static Id brokerRecordTypeId() {
        return Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName().get('Broker').getRecordTypeId();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // The match matrix (D1)
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * Contact + Account both exist: the Contact matches on email and the Account returned is the
     * CONTACT'S OWN Account — the invariant that makes setContactId legal (Salesforce rejects a
     * Contact that does not belong to the target Account).
     */
    @isTest
    static void matchForConversion_contactExists_returnsContactAndItsOwnAccount() {
        Account firm = buildFirm('Marcus Millichap Match Test');
        insert firm;
        Contact broker = buildBroker('repeat.broker@firm.invalid', firm.Id);
        insert broker;
        Lead l = buildLead('repeat.broker@firm.invalid', 'Some Other Company Name');
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.isTrue(matches.containsKey(l.Id), 'A Lead whose email matches an existing Contact should match');
        Assert.areEqual(broker.Id, matches.get(l.Id).contactId, 'The existing broker Contact should be the target');
        Assert.areEqual(firm.Id, matches.get(l.Id).accountId,
            'The Account must be the matched Contact\'s own Account — setContactId is invalid otherwise');
    }

    /**
     * CONTACT WINS AND DICTATES THE ACCOUNT. The Lead's Company here is the exact name of a
     * DIFFERENT existing Account, so if Company were consulted at all the wrong Account would come
     * back. It must be ignored entirely once a Contact matched (a Salesforce constraint, not a
     * preference).
     */
    @isTest
    static void matchForConversion_contactMatch_ignoresACompanyThatMatchesADifferentAccount() {
        // Allow-save: these two names share the token 'Firm' and the standard Account rule matches
        // fuzzily (see TestDataFactory.insertAllowingDuplicates). They remain DISTINCT records,
        // which is all this test needs.
        Account contactsFirm = buildFirm('Contacts Own Firm');
        Account companyNamedFirm = buildFirm('Company Named Firm');
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ contactsFirm, companyNamedFirm });
        Contact broker = buildBroker('both.paths@firm.invalid', contactsFirm.Id);
        insert broker;
        // Company deliberately names the OTHER account.
        Lead l = buildLead('both.paths@firm.invalid', 'Company Named Firm');
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.areEqual(broker.Id, matches.get(l.Id).contactId, 'The Contact match should win');
        Assert.areEqual(contactsFirm.Id, matches.get(l.Id).accountId,
            'The Contact\'s Account must win over the Account named by Lead.Company');
        Assert.areNotEqual(companyNamedFirm.Id, matches.get(l.Id).accountId,
            'Lead.Company must be ignored once a Contact matched');
    }

    /**
     * The "company half" of the feature: a NEW broker (no Contact anywhere) whose email carried a
     * real firm name lands under that firm's existing Account instead of creating a second one.
     */
    @isTest
    static void matchForConversion_accountNameMatchesAndNoContact_returnsAccountOnly() {
        Account firm = buildFirm('Existing Brokerage Firm LLC');
        insert firm;
        Lead l = buildLead('brand.new.broker@firm.invalid', 'Existing Brokerage Firm LLC');
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.isTrue(matches.containsKey(l.Id), 'A Lead whose Company names an existing Account should match');
        Assert.areEqual(firm.Id, matches.get(l.Id).accountId, 'The existing firm Account should be the target');
        Assert.isNull(matches.get(l.Id).contactId,
            'No Contact exists for this email, so the platform must still create one');
    }

    /** Neither key matches: no entry at all, so the Lead converts with no attach target. */
    @isTest
    static void matchForConversion_neitherMatches_returnsNoEntry() {
        insert buildFirm('Some Unrelated Firm');
        insert buildBroker('someone.else@firm.invalid', null);
        Lead l = buildLead('nobody.knows.me@firm.invalid', 'Nobody Knows This Company');
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.isFalse(matches.containsKey(l.Id),
            'An unmatched Lead must be absent from the map so conversion gets no attach target');
    }

    /**
     * Email matching is CASE-INSENSITIVE end to end. SOQL comparison already is, but Apex Map keys
     * are NOT — so this pins LeadConvertMatchService.normalizeKey, without which the query would
     * return the row and the map would then fail to pair it with its Lead.
     *
     * SCOPE IS CASE ONLY, DELIBERATELY. normalizeKey also trims, but no whitespace fixture is
     * asserted here: whether the platform stores a leading/trailing space on an Email field at all
     * is undocumented and was not verified, so a whitespace case would be asserting a guess about
     * platform behaviour rather than about this class. Do not add one without measuring it first.
     */
    @isTest
    static void matchForConversion_emailCaseDiffers_stillMatches() {
        Account firm = buildFirm('Case Test Firm');
        insert firm;
        Contact broker = buildBroker('Mixed.Case.Broker@Firm.Invalid', firm.Id);
        insert broker;
        Lead l = buildLead('mixed.case.broker@firm.invalid', 'Case Test Company');
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.areEqual(broker.Id, matches.get(l.Id).contactId,
            'Email matching must be case-insensitive on BOTH the query and the Map key');
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // D1b — the crux. Named for the decision it pins.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * THE D1b DECISION, PINNED. Two different brokers whose firm could not be extracted both carry
     * Company = 'Unknown - Via Email'. They must NOT be bucketed into one shared Account.
     *
     * Bucketing was rejected because BrokerFirmController.getBrokerFirm +
     * OpportunitySelector.countByStageForAccount aggregate every Opportunity on an Account into
     * that firm's deal counts and name the earliest Contact on it as "the broker" — so a shared
     * placeholder Account would put an actively wrong answer on a live page, in the one module
     * whose whole purpose is broker attribution.
     *
     * An Account ALREADY NAMED with the placeholder is pre-created here on purpose: the rule is
     * not "there is nothing to match", it is "we refuse to match this value even when we could".
     * Then both Leads are really converted, because the user-visible consequence is the count of
     * Accounts, not the shape of a map.
     */
    @isTest
    static void placeholderCompany_doesNotBucketUnrelatedBrokers() {
        Account preExistingPlaceholder = buildFirm(EmailToLeadService.COMPANY_PLACEHOLDER);
        insert preExistingPlaceholder;

        Lead brokerA = buildLead('broker.alpha@firm.invalid', EmailToLeadService.COMPANY_PLACEHOLDER);
        Lead brokerB = buildLead('broker.beta@firm.invalid', EmailToLeadService.COMPANY_PLACEHOLDER);
        insert new List<Lead>{ brokerA, brokerB };

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ brokerA.Id, brokerB.Id });
        LeadConvertActionService.convert(new List<Id>{ brokerA.Id, brokerB.Id });
        Test.stopTest();

        // The decision itself.
        Assert.isFalse(matches.containsKey(brokerA.Id),
            'The placeholder Company must never match an Account, even one that carries that exact name');
        Assert.isFalse(matches.containsKey(brokerB.Id),
            'The placeholder Company must never match an Account, even one that carries that exact name');

        // The user-visible consequence.
        Map<Id, Lead> converted = new Map<Id, Lead>([
            SELECT Id, ConvertedAccountId FROM Lead WHERE Id IN :new List<Id>{ brokerA.Id, brokerB.Id }
        ]);
        Id accountA = converted.get(brokerA.Id).ConvertedAccountId;
        Id accountB = converted.get(brokerB.Id).ConvertedAccountId;
        Assert.areNotEqual(accountA, accountB,
            'Two unrelated firm-unknown brokers must land on TWO Accounts, never one shared bucket');
        Assert.areNotEqual(preExistingPlaceholder.Id, accountA,
            'Neither broker may be attached to the pre-existing placeholder-named Account');
        Assert.areNotEqual(preExistingPlaceholder.Id, accountB,
            'Neither broker may be attached to the pre-existing placeholder-named Account');
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // D2 — determinism. Aged with Test.setCreatedDate, never insert order.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * Oldest Contact wins. The older record is deliberately the SECOND one inserted, so it also
     * has the HIGHER Id — a test built on insert order or Id order would pick the wrong record and
     * pass for the wrong reason. Records inserted in one transaction can share a CreatedDate,
     * which is exactly why Id is only the tiebreak.
     */
    @isTest
    static void matchForConversion_multipleContactsSameEmail_oldestWins() {
        // Routed through the allow-save helper: the standard Account rule matches on a FUZZY name,
        // so two short names sharing the token 'Firm' can match each other even though they are
        // not duplicates in any meaningful sense. See TestDataFactory.insertAllowingDuplicates.
        Account newerFirm = buildFirm('Newer Firm');
        Account olderFirm = buildFirm('Older Firm');
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ newerFirm, olderFirm });

        // Two Contacts sharing an Email is duplicate-shaped ON PURPOSE — it is the only way to
        // express this tie-break — so the org's active (Alert-mode) Contact rule must be told to
        // alert-but-save. See TestDataFactory.insertAllowingDuplicates for why. Inserted
        // SEPARATELY, not as one list, because the second must get the higher Id.
        String sharedEmail = 'duplicated.broker@firm.invalid';
        Contact newerContact = buildBroker(sharedEmail, newerFirm.Id);
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ newerContact });
        Contact olderContact = buildBroker(sharedEmail, olderFirm.Id);
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ olderContact });
        Test.setCreatedDate(olderContact.Id, Datetime.now().addYears(-2));

        Lead l = buildLead(sharedEmail, 'Determinism Test Company');
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.areEqual(olderContact.Id, matches.get(l.Id).contactId,
            'The OLDEST Contact must win — it carries the most history and is the record a merge would keep');
        Assert.areEqual(olderFirm.Id, matches.get(l.Id).accountId,
            'The Account must follow the winning Contact');
    }

    /** Oldest Account wins, same construction: the older record is inserted second. */
    @isTest
    static void matchForConversion_multipleAccountsSameName_oldestWins() {
        // Two Accounts sharing a Name is duplicate-shaped ON PURPOSE (see
        // TestDataFactory.insertAllowingDuplicates). Inserted separately so the older one, aged
        // below, also carries the HIGHER Id — which is what makes this test discriminate.
        Account newerFirm = buildFirm('Ambiguous Firm Name');
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ newerFirm });
        Account olderFirm = buildFirm('Ambiguous Firm Name');
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ olderFirm });
        Test.setCreatedDate(olderFirm.Id, Datetime.now().addYears(-2));

        Lead l = buildLead('no.contact.here@firm.invalid', 'Ambiguous Firm Name');
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.areEqual(olderFirm.Id, matches.get(l.Id).accountId,
            'The OLDEST Account must win, so repeated conversions converge on one canonical firm record');
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Guards
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * An orphan Contact (no AccountId) must never match. Salesforce requires the conversion target
     * Contact to belong to the target Account, so attaching to one would make convertLead throw.
     * The exclusion lives in the selector's WHERE clause, so this also proves there is no code path
     * that can reintroduce it. Accepted consequence (L1): this broker still gets a duplicate.
     */
    @isTest
    static void matchForConversion_orphanContactWithoutAccount_isNotMatched() {
        Contact orphan = buildBroker('orphan.broker@firm.invalid', null);
        insert orphan;
        Lead l = buildLead('orphan.broker@firm.invalid', 'Orphan Test Company');
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.isFalse(matches.containsKey(l.Id),
            'An account-less Contact must be treated as no-match, not as a target convertLead would reject');
    }

    @isTest
    static void matchForConversion_nullInput_returnsEmptyMap() {
        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches = LeadConvertMatchService.matchForConversion(null);
        Test.stopTest();

        Assert.isNotNull(matches, 'A null input must still return a map, not null');
        Assert.isTrue(matches.isEmpty(), 'A null input must return an empty map');
        Assert.isFalse(LeadConvertMatchService.lastRunDegraded,
            'An empty input is not a degrade — the flag must stay false so it only ever means "read denied"');
    }

    @isTest
    static void matchForConversion_emptyInput_returnsEmptyMapWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>());
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.isTrue(matches.isEmpty(), 'An empty input must return an empty map');
        Assert.areEqual(0, after - before, 'An empty input must cost no SOQL at all');
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Fail-soft seam
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * THE DEGRADE SEAM. `WITH USER_MODE` THROWS rather than degrading when the running user cannot
     * read the match fields, and a raw throw here would have REGRESSED conversion for users who
     * can convert today — this feature would have made the app worse for them. So a denied read
     * must return an empty map and set lastRunDegraded.
     *
     * The denial is created at OBJECT level (a 'Minimum Access - Salesforce' user), not field
     * level, on purpose: the fields read here (Lead.Email, Contact.Email, Account.Name) are
     * STANDARD fields that a Standard User profile already grants, so a bare-Standard-User runAs —
     * the pattern that works elsewhere in this repo for CUSTOM fields — would NOT deny anything
     * and the test would silently prove nothing. All three reads share one catch, so denying the
     * first is sufficient to exercise it.
     *
     * Asserting the flag is the point: without the seam a silent fallback is indistinguishable
     * from "nothing matched", which is the failure mode this module has been bitten by before.
     */
    @isTest
    static void matchForConversion_readDenied_degradesToNoMatchAndFlagsIt() {
        Account firm = buildFirm('Degrade Test Firm');
        insert firm;
        Contact broker = buildBroker('degrade.broker@firm.invalid', firm.Id);
        insert broker;
        Lead l = buildLead('degrade.broker@firm.invalid', 'Degrade Test Company');
        insert l;

        // User + setup DML isolated in its own runAs to avoid MIXED_DML_OPERATION with the
        // non-setup DML above (the repo's established pattern).
        User restricted = buildMinimumAccessUser();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert restricted;
        }

        Map<Id, LeadConvertMatchService.ConversionMatch> matches;
        Boolean degraded;
        Test.startTest();
        System.runAs(restricted) {
            matches = LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
            degraded = LeadConvertMatchService.lastRunDegraded;
        }
        Test.stopTest();

        Assert.isNotNull(matches, 'A denied read must return a map, not null and not an exception');
        Assert.isTrue(matches.isEmpty(),
            'A denied read must degrade to no-match so conversion still proceeds, attaching nothing '
            + '(NOT the pre-change outcome — the bypass means it now succeeds silently rather than blocking)');
        Assert.isTrue(degraded,
            'lastRunDegraded must be set — a silent degrade is indistinguishable from "nothing matched"');
    }

    /** The flag is per-run state, not sticky: a later clean run must clear it. */
    @isTest
    static void matchForConversion_lastRunDegraded_isResetOnEachCall() {
        Lead l = buildLead('reset.check@firm.invalid', 'Reset Check Company');
        insert l;

        Test.startTest();
        LeadConvertMatchService.lastRunDegraded = true;   // simulate a prior degraded run
        LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        Assert.isFalse(LeadConvertMatchService.lastRunDegraded,
            'lastRunDegraded describes the LAST run only; a successful run must clear it');
    }

    private static User buildMinimumAccessUser() {
        Profile minimumAccess = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = 'lcmsmin' + String.valueOf(Datetime.now().getTime());
        return new User(
            FirstName = 'Min',
            LastName = 'MatchSvc',
            Alias = 'lcmsmin',
            Email = 'min.matchsvc@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Bulk — the governor-headroom budget
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * 251 Leads, mixed across all three outcomes, resolved in ONE call.
     *
     * The SOQL-delta assertion is the real subject. The service's bulk shape is a CONTRACT — three
     * queries regardless of N — and this is what makes a regression to per-Lead querying fail here
     * instead of in production, where 251 Leads would blow the 100-query limit at Lead 34.
     */
    @isTest
    static void matchForConversion_at251Leads_isBulkSafe() {
        final Integer leadCount = 251;

        Account firm = buildFirm('Bulk Firm Account');
        insert firm;
        Contact broker = buildBroker('bulk.broker@firm.invalid', firm.Id);
        insert broker;

        List<Lead> leads = TestDataFactory.createLeads(leadCount, false);
        for (Integer i = 0; i < leadCount; i++) {
            if (Math.mod(i, 3) == 0) {
                leads[i].Email = 'bulk.broker@firm.invalid';          // contact match
            } else if (Math.mod(i, 3) == 1) {
                leads[i].Company = 'Bulk Firm Account';                // account-name match
            }
            // i % 3 == 2 keeps the factory's unique email + company -> no match
        }
        insert leads;

        // Built in insert order so leadIds[i] stays aligned with the i-based outcome below.
        List<Id> leadIds = new List<Id>();
        for (Lead l : leads) {
            leadIds.add(l.Id);
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(leadIds);
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        Integer queryDelta = queriesAfter - queriesBefore;
        Assert.isTrue(queryDelta <= 3,
            'BUDGET: at most 3 SOQL (lead keys, contacts, accounts) for ANY number of Leads. '
            + 'Observed ' + queryDelta + ' for ' + leadCount + ' Leads — a per-Lead query would blow the '
            + '100-query limit at Lead 34 in production.');

        Integer contactMatches = 0;
        Integer accountOnlyMatches = 0;
        Integer noMatches = 0;
        for (Integer i = 0; i < leadCount; i++) {
            LeadConvertMatchService.ConversionMatch match = matches.get(leadIds[i]);
            if (Math.mod(i, 3) == 0) {
                Assert.isNotNull(match, 'Lead ' + i + ' shares the broker email and must match');
                Assert.areEqual(broker.Id, match.contactId, 'Lead ' + i + ' must attach to the existing Contact');
                Assert.areEqual(firm.Id, match.accountId, 'Lead ' + i + ' must attach to that Contact\'s Account');
                contactMatches++;
            } else if (Math.mod(i, 3) == 1) {
                Assert.isNotNull(match, 'Lead ' + i + ' names an existing Account and must match');
                Assert.isNull(match.contactId, 'Lead ' + i + ' has no existing Contact');
                Assert.areEqual(firm.Id, match.accountId, 'Lead ' + i + ' must attach to the existing firm Account');
                accountOnlyMatches++;
            } else {
                Assert.isNull(match, 'Lead ' + i + ' matches nothing and must be absent from the map');
                noMatches++;
            }
        }

        Assert.areEqual(leadCount, contactMatches + accountOnlyMatches + noMatches,
            'Every one of the 251 Leads must be accounted for');
        Assert.areEqual(contactMatches + accountOnlyMatches, matches.size(),
            'The map must contain an entry for exactly the matched Leads and no others');
        Assert.isFalse(LeadConvertMatchService.lastRunDegraded, 'The bulk run must not have degraded');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // WS8 (2026-08-30) — PREFER THE INTAKE-TIME BROKER LINK
    //
    // 🔴 EVERY TEST BELOW IS FLS-BRANCHED, AND BOTH BRANCHES ASSERT SOMETHING REAL. `Lead.Broker__c`
    // and `Lead.Broker_Firm__c` are new Metadata-API-deployed fields, so on the day WS8 lands NO
    // PRINCIPAL CAN WRITE OR READ THEM — a test fixture that set them unconditionally would throw
    // `System.DmlException: Operation failed due to fields being inaccessible on Sobject Lead` at
    // `insert l` and take this whole class down (measured shape, 2026-08-30, on WS7's two fields:
    // 42 of 45 methods red, 38 of them unrelated).
    //
    // ⚠ SO THE `else` BRANCHES ARE NOT FILLER. They assert that the OLD behaviour — the email and
    // company matching this class shipped on 2026-08-02 — is byte-identical when the link is not
    // available. That is the property that makes WS8 a STRENGTHENING rather than a replacement,
    // and it is the one that must hold in every org from the moment this deploys.
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** True when the running principal may WRITE both WS8 lookups (fixtures depend on this). */
    private static Boolean brokerLinkWritable() {
        return Schema.SObjectType.Lead.fields.Broker__c.isCreateable()
            && Schema.SObjectType.Lead.fields.Broker_Firm__c.isCreateable();
    }

    /**
     * Stamp the intake broker link onto an UNSAVED Lead, when the running principal may.
     *
     * @param l         The unsaved Lead.
     * @param contactId The broker Contact, or null to leave `Broker__c` blank.
     * @param accountId The brokerage Account, or null to leave `Broker_Firm__c` blank.
     * @return True when the link was actually stamped; false when FLS forbids it and the caller
     *         must assert the pre-WS8 behaviour instead.
     */
    private static Boolean linkBroker(Lead l, Id contactId, Id accountId) {
        if (!brokerLinkWritable()) {
            return false;
        }
        l.Broker__c = contactId;
        l.Broker_Firm__c = accountId;
        return true;
    }

    @isTest
    static void matchForConversion_intakeBrokerLink_beatsTheEmailMatch() {
        // 🔴 THE PRECEDENCE PROOF, MADE NON-VACUOUS BY DISAGREEMENT. The Lead's EMAIL names one
        // broker and its `Broker__c` names a DIFFERENT one, each under a different firm. If the
        // link did not take precedence, the email broker would come back and this fails.
        Account linkedFirm = buildFirm('Linked Firm WS8');
        Account emailFirm = buildFirm('Email Firm WS8');
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ linkedFirm, emailFirm });
        Contact linkedBroker = buildBroker('linked.broker.ws8@firm.invalid', linkedFirm.Id);
        Contact emailBroker = buildBroker('email.broker.ws8@firm.invalid', emailFirm.Id);
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ linkedBroker, emailBroker });

        Lead l = buildLead('email.broker.ws8@firm.invalid', 'Some Unrelated Company');
        Boolean linked = linkBroker(l, linkedBroker.Id, linkedFirm.Id);
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        LeadConvertMatchService.ConversionMatch match = matches.get(l.Id);
        Assert.isNotNull(match, 'Either way this Lead matches something — only WHICH thing differs');
        if (linked) {
            Assert.areEqual(linkedBroker.Id, match.contactId,
                'THE INTAKE LINK WINS. It is a higher-confidence source for the same answer: intake '
                + 'resolved it against Contact.Email on the Broker record type with AccountId != null, '
                + 'the same predicate this class uses at conversion');
            Assert.areEqual(linkedFirm.Id, match.accountId,
                '🔴 AND THE ACCOUNT IS SPANNED THROUGH THE CONTACT (Broker__r.AccountId), NOT READ '
                + 'FROM Broker_Firm__c. That is what keeps the ConversionMatch invariant true by '
                + 'construction, so Database.convertLead can never be handed a Contact that does not '
                + 'belong to the Account');
        } else {
            Assert.areEqual(emailBroker.Id, match.contactId,
                'WITHOUT the FLS grant the link is invisible and the 2026-08-02 EMAIL match still runs, '
                + 'unchanged. This branch is the regression pin: WS8 must never make matching WORSE');
            Assert.areEqual(emailFirm.Id, match.accountId, 'with that Contact\'s own Account, as before');
        }
    }

    @isTest
    static void matchForConversion_intakeBrokerLink_matchesWhereTheEmailMatchCannot() {
        // 🔴 THE HOLE WS8 CLOSES, WHICH IS THE WHOLE JUSTIFICATION FOR THE CHANGE. The broker's
        // Contact exists, but the Lead's Email no longer resolves to it — a Contact whose address
        // was updated, or a Lead.Email a human corrected after intake. Before WS8 this Lead would
        // convert by minting a SECOND Contact for a person we already have, which is the exact
        // DUPLICATES_DETECTED shape this class was built for.
        Account firm = buildFirm('Renamed Firm WS8');
        insert firm;
        Contact broker = buildBroker('current.address.ws8@firm.invalid', firm.Id);
        insert broker;

        Lead l = buildLead('stale.address.ws8@firm.invalid', 'Some Unrelated Company');
        Boolean linked = linkBroker(l, broker.Id, firm.Id);
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        if (linked) {
            LeadConvertMatchService.ConversionMatch match = matches.get(l.Id);
            Assert.isNotNull(match,
                'The Lead matches through the LINK even though its Email resolves to no Contact');
            Assert.areEqual(broker.Id, match.contactId, 'and attaches to the broker we already have');
            Assert.areEqual(firm.Id, match.accountId, 'under that Contact\'s own Account');
        } else {
            Assert.isFalse(matches.containsKey(l.Id),
                'WITHOUT the grant this is the PRE-WS8 behaviour and the duplicate is still minted — '
                + 'stated plainly rather than hidden, because it is exactly what the P8 FLS grant buys');
        }
    }

    @isTest
    static void matchForConversion_brokerFirmLinkOnly_beatsTheCompanyNameMatch() {
        // PRECEDENCE 3. No Contact is being specified, so no invariant arises: an accountId with a
        // null contactId is the legitimate firm-only match this class has always produced. The
        // explicit lookup outranks the Company STRING, which on an email-born Lead is an LLM's
        // reading of a signature block.
        Account linkedFirm = buildFirm('Explicit Firm WS8');
        Account namedFirm = buildFirm('Named Firm WS8');
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ linkedFirm, namedFirm });

        Lead l = buildLead('nobody.ws8@firm.invalid', 'Named Firm WS8');
        Boolean linked = linkBroker(l, null, linkedFirm.Id);
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        LeadConvertMatchService.ConversionMatch match = matches.get(l.Id);
        Assert.isNotNull(match, 'Either way the Lead matches a firm — only WHICH firm differs');
        Assert.isNull(match.contactId, 'No Contact is specified on either path — this is firm-only');
        if (linked) {
            Assert.areEqual(linkedFirm.Id, match.accountId,
                'The EXPLICIT firm lookup wins over the Company name string');
        } else {
            Assert.areEqual(namedFirm.Id, match.accountId,
                'and without the grant the D1b Company-name match still runs exactly as before');
        }
    }

    @isTest
    static void matchForConversion_brokerLinkWithoutAnAccount_fallsBackRatherThanBreakingConversion() {
        // ⚠ AN ACCOUNT-LESS `Broker__c` IS NOT A USABLE CONVERSION TARGET — `setContactId` is valid
        // only alongside a `setAccountId` for that Contact's OWN Account, so specifying one would
        // make `Database.convertLead` THROW and break a conversion that works today. Intake's
        // selector already excludes orphans, so this state is only reachable by hand-editing; the
        // correct response is to fall through to the ordinary email match, NOT to throw.
        Account firm = buildFirm('Orphan Fallback Firm WS8');
        insert firm;
        Contact orphan = buildBroker('orphan.link.ws8@firm.invalid', null);
        Contact emailBroker = buildBroker('email.fallback.ws8@firm.invalid', firm.Id);
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ orphan, emailBroker });

        Lead l = buildLead('email.fallback.ws8@firm.invalid', 'Some Unrelated Company');
        linkBroker(l, orphan.Id, null);
        insert l;

        Test.startTest();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(new List<Id>{ l.Id });
        Test.stopTest();

        LeadConvertMatchService.ConversionMatch match = matches.get(l.Id);
        Assert.isNotNull(match, 'The Lead must still match — falling through is not failing');
        Assert.areEqual(emailBroker.Id, match.contactId,
            'The ORPHAN link is skipped and the EMAIL match runs. If this returns the orphan, a '
            + 'hand-edited lookup has been turned into a hard conversion failure');
        Assert.areEqual(firm.Id, match.accountId, 'with the email-matched Contact\'s own Account');
        Assert.isFalse(LeadConvertMatchService.lastRunDegraded,
            'and nothing degraded — an unusable link is a normal state, not a denied read');
    }

    @isTest
    static void matchForConversion_at251LeadsWithBrokerLinks_isStillThreeQueries() {
        // 🔴 THE BULK CONTRACT IS UNCHANGED BY WS8, AND THIS IS WHERE THAT IS PROVEN. The link is
        // read as THREE MORE COLUMNS ON THE EXISTING FIRST QUERY, and the choice between the two
        // column sets is a CACHED DESCRIBE — not a second read, and not one describe per Lead.
        // Mirrors matchForConversion_at251Leads_isBulkSafe above deliberately, against the SAME
        // named budget, so a regression shows up against an unchanged number.
        final Integer leadCount = 251;

        Account firm = buildFirm('Bulk WS8 Firm Account');
        insert firm;
        Contact broker = buildBroker('bulk.ws8.broker@firm.invalid', firm.Id);
        insert broker;

        List<Lead> leads = TestDataFactory.createLeads(leadCount, false);
        for (Integer i = 0; i < leadCount; i++) {
            if (Math.mod(i, 3) == 0) {
                linkBroker(leads[i], broker.Id, firm.Id);               // intake-link match
            } else if (Math.mod(i, 3) == 1) {
                leads[i].Email = 'bulk.ws8.broker@firm.invalid';        // email match
            }
            // i % 3 == 2 keeps the factory's unique email + company -> no match
        }
        insert leads;

        List<Id> leadIds = new List<Id>();
        for (Lead l : leads) {
            leadIds.add(l.Id);
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(leadIds);
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        Integer queryDelta = queriesAfter - queriesBefore;
        Assert.isTrue(queryDelta <= 3,
            'BUDGET UNMOVED BY WS8: at most 3 SOQL (lead keys, contacts, accounts) for ANY number of '
            + 'Leads. Observed ' + queryDelta + ' for ' + leadCount + ' Leads. A per-Lead re-read of '
            + 'the broker link would blow the 100-query limit at Lead 34 in production.');

        Boolean linked = brokerLinkWritable();
        for (Integer i = 0; i < leadCount; i++) {
            LeadConvertMatchService.ConversionMatch match = matches.get(leadIds[i]);
            if (Math.mod(i, 3) == 0) {
                if (linked) {
                    Assert.isNotNull(match, 'Lead ' + i + ' carries an intake link and must match');
                    Assert.areEqual(broker.Id, match.contactId,
                        'Lead ' + i + ' must attach through its LINK, at 251 exactly as at 1');
                    Assert.areEqual(firm.Id, match.accountId,
                        'Lead ' + i + ' must attach to that Contact\'s own Account, spanned not copied');
                } else {
                    Assert.isNull(match,
                        'Lead ' + i + ' has no readable link and no matching email — the pre-WS8 answer');
                }
            } else if (Math.mod(i, 3) == 1) {
                Assert.isNotNull(match, 'Lead ' + i + ' shares the broker email and must match');
                Assert.areEqual(broker.Id, match.contactId,
                    'Lead ' + i + ' must still attach through the UNCHANGED email path');
            } else {
                Assert.isNull(match, 'Lead ' + i + ' matches nothing and must be absent from the map');
            }
        }
        Assert.isFalse(LeadConvertMatchService.lastRunDegraded,
            '🔴 AND THE BULK RUN MUST NOT HAVE DEGRADED. A degrade here would mean the WS8 columns '
            + 'were selected without the describe gate, which returns an EMPTY map and silently '
            + 'disables ALL matching — the exact regression brokerLinkReadable() exists to prevent');
    }
}
