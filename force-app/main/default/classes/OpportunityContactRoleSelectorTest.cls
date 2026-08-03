/**
 * Tests for OpportunityContactRoleSelector — the first (and only) OpportunityContactRole SOQL in
 * the application, added with Conversion Enrichment S2
 * (`agent-output/design-requirements-conversion-enrichment.md` §4/§9.3).
 *
 * The selector exists so LeadConvertService's broker-role write can be a READ-then-write: standard
 * lead conversion already creates a primary role row with a blank Role, and a blind insert would
 * leave the deal with two rows for one Contact and a second primary. Everything below therefore
 * pins the three properties that read depends on — the row is FOUND, it carries the ContactId and
 * IsPrimary the caller decides on, and finding it costs ONE query no matter how many Opportunities
 * are asked about.
 *
 * Roles are created explicitly here rather than by converting Leads: the point of these tests is
 * to control the (Opportunity, Contact, Role, IsPrimary) shape directly. The conversion-level
 * coverage of the same query lives in LeadConvertServiceTest.
 *
 * @see force-app/main/default/classes/OpportunityContactRoleSelector.cls
 * @see force-app/main/default/classes/AccountSelectorTest.cls (the pattern this follows)
 */
@isTest
private class OpportunityContactRoleSelectorTest {

    private static final Integer BULK_N = 251;

    // ── EVERY Account AND Contact IN THIS CLASS IS SEEDED THROUGH THE TWO HELPERS BELOW ─────────
    // ⚠ THE ORG'S DUPLICATE RULES ARE LIVE AND THE FACTORY'S ROWS ARE DUPLICATE-SHAPED BY DESIGN.
    // TestDataFactory.createAccounts stamps EVERY row BillingCity='Houston' / BillingState='TX' and
    // names them 'Test Account <i>-<unique>', which the standard Account rule fuzzy-matches — its
    // own header says two separate createAccount(true) calls in one transaction are already enough
    // to trip it. Contacts are worse in this class: createContacts numbers LastName from 0 on EVERY
    // call, so two single-Contact seeds both produce 'Test Contact 0'.
    //
    // That is exactly how selectByOpportunityIds_scopesToTheRequestedOpportunities failed with
    // DUPLICATES_DETECTED (it calls seedRole twice). The other methods happen to seed only one
    // Account each and so pass today — but that is incidental, not a property anyone would notice
    // breaking, so all six sites are routed through the guards rather than only the one that blew
    // up. AllowSave suppresses the duplicate ALERT only; optAllOrNone stays true, so a real error
    // still throws, and the rows/Ids/values these tests assert on are completely unchanged.
    // (Pattern: ContactSelectorTest, which was consolidated onto the same helper.)

    /** Duplicate-safe Account seed. */
    private static Account seedFirm() {
        Account firm = TestDataFactory.createAccount(false);
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ firm });
        return firm;
    }

    /** Duplicate-safe Contact seed under a firm. */
    private static Contact seedBroker(Id accountId) {
        Contact broker = TestDataFactory.createContact(accountId, false);
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ broker });
        return broker;
    }

    /**
     * One Opportunity + one Contact + one role row linking them. Returns the role's parent
     * Opportunity Id. Callable more than once per transaction — see the note above.
     */
    private static Id seedRole(String role, Boolean isPrimary) {
        Account firm = seedFirm();
        Contact broker = seedBroker(firm.Id);
        Opportunity deal = TestDataFactory.createOpportunity(firm.Id, true);
        insert new OpportunityContactRole(
            OpportunityId = deal.Id,
            ContactId = broker.Id,
            Role = role,
            IsPrimary = isPrimary
        );
        return deal.Id;
    }

    @isTest
    static void selectByOpportunityIds_returnsTheRoleWithEveryFieldTheCallerNeeds() {
        Account firm = seedFirm();
        Contact broker = seedBroker(firm.Id);
        Opportunity deal = TestDataFactory.createOpportunity(firm.Id, true);
        insert new OpportunityContactRole(
            OpportunityId = deal.Id, ContactId = broker.Id, Role = 'Broker', IsPrimary = true
        );

        Test.startTest();
        List<OpportunityContactRole> rows =
            OpportunityContactRoleSelector.selectByOpportunityIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The Opportunity\'s single role row should be returned');
        Assert.areEqual(deal.Id, rows[0].OpportunityId, 'OpportunityId is selected — it is half the match key');
        Assert.areEqual(broker.Id, rows[0].ContactId,
            'ContactId is selected — without it the caller could not tell "the row for OUR Contact" '
            + 'from a role somebody added for a different Contact');
        Assert.areEqual('Broker', rows[0].Role, 'Role is selected so the caller can see what it is changing');
        Assert.isTrue(rows[0].IsPrimary,
            'IsPrimary is selected so the caller can SKIP re-asserting primary on a row that already has it');
        Assert.isNotNull(rows[0].Id,
            'The row Id is selected — it is what puts this row in the caller\'s UPDATE partition '
            + 'instead of its INSERT partition');
    }

    /**
     * The blank-Role row is the realistic production shape: it is exactly what standard lead
     * conversion leaves behind, and the row LeadConvertService must find rather than duplicate.
     */
    @isTest
    static void selectByOpportunityIds_findsARowWithABlankRole() {
        Account firm = seedFirm();
        Contact broker = seedBroker(firm.Id);
        Opportunity deal = TestDataFactory.createOpportunity(firm.Id, true);
        insert new OpportunityContactRole(
            OpportunityId = deal.Id, ContactId = broker.Id, IsPrimary = true
        );

        Test.startTest();
        List<OpportunityContactRole> rows =
            OpportunityContactRoleSelector.selectByOpportunityIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'A role row with no Role value must still be FOUND — this is the row standard conversion '
            + 'creates, and missing it is precisely how a duplicate broker row gets inserted');
        Assert.isNull(rows[0].Role, 'and it comes back with its blank Role, which the caller then fills');
    }

    @isTest
    static void selectByOpportunityIds_scopesToTheRequestedOpportunities() {
        Id wanted = seedRole('Broker', true);
        Id unrelated = seedRole('Influencer', true);

        Test.startTest();
        List<OpportunityContactRole> rows =
            OpportunityContactRoleSelector.selectByOpportunityIds(new Set<Id>{ wanted });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the requested Opportunity\'s roles should come back');
        Assert.areEqual(wanted, rows[0].OpportunityId, 'and it is the requested Opportunity\'s row');
        Assert.areNotEqual(unrelated, rows[0].OpportunityId,
            'A role on an Opportunity outside the converted set must never leak in — the caller would '
            + 'otherwise key it into its pair map and consider that deal already handled');
    }

    @isTest
    static void selectByOpportunityIds_returnsEveryRoleOnTheOpportunity() {
        Account firm = seedFirm();
        List<Contact> people = TestDataFactory.createContacts(2, firm.Id, false);
        TestDataFactory.insertAllowingDuplicates(people);
        Opportunity deal = TestDataFactory.createOpportunity(firm.Id, true);
        insert new List<OpportunityContactRole>{
            new OpportunityContactRole(OpportunityId = deal.Id, ContactId = people[0].Id,
                Role = 'Broker', IsPrimary = true),
            new OpportunityContactRole(OpportunityId = deal.Id, ContactId = people[1].Id,
                Role = 'Influencer', IsPrimary = false)
        };

        Test.startTest();
        List<OpportunityContactRole> rows =
            OpportunityContactRoleSelector.selectByOpportunityIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            'The query is scoped by OPPORTUNITY, not by (Opportunity, Contact) pair — a pair-scoped '
            + 'query would need one SOQL per pair, which is the per-record query the 2-SOQL contract '
            + 'forbids. The caller narrows to its Contact in memory');
    }

    @isTest
    static void selectByOpportunityIds_noMatch_returnsEmpty() {
        Account firm = seedFirm();
        Opportunity roleless = TestDataFactory.createOpportunity(firm.Id, true);

        Test.startTest();
        List<OpportunityContactRole> rows =
            OpportunityContactRoleSelector.selectByOpportunityIds(new Set<Id>{ roleless.Id });
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'An Opportunity with no roles returns an empty list, not null — the caller then takes its '
            + 'INSERT branch for that deal');
    }

    @isTest
    static void selectByOpportunityIds_nullOrEmptyInput_returnsEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<OpportunityContactRole> forNull = OpportunityContactRoleSelector.selectByOpportunityIds(null);
        List<OpportunityContactRole> forEmpty =
            OpportunityContactRoleSelector.selectByOpportunityIds(new Set<Id>());
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null Id set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty Id set short-circuits to an empty list, not null');
        Assert.areEqual(0, after - before,
            'Neither call may spend a query — the guard runs before the SOQL. LeadConvertService '
            + 'reaches this path whenever no converted Lead carries a ConvertedContactId, and it must '
            + 'not pay a query for nothing');
    }

    /**
     * Bulk-safety at data volume per `.claude/rules/bulk-test-rule.md`, independent of the
     * SERVICE-level 251 proof in LeadConvertServiceTest. The sharp assertion is the query COUNT:
     * this selector is SOQL 2 of LeadConvertService's 2-SOQL contract, so one query for 251
     * Opportunities is the contract itself, not a nicety.
     */
    @isTest
    static void selectByOpportunityIds_251Opportunities_returnsAllInOneQuery() {
        Account firm = seedFirm();
        // Contacts differing only by a trailing counter are FUZZY-identical to the standard
        // duplicate rule (see AccountSelectorTest's note on the same trap), so allow-save the seed.
        // It changes nothing about the rows this selector reads.
        List<Contact> brokers = TestDataFactory.createContacts(BULK_N, firm.Id, false);
        TestDataFactory.insertAllowingDuplicates(brokers);
        List<Opportunity> deals = TestDataFactory.createOpportunities(BULK_N, firm.Id, true);

        List<OpportunityContactRole> roles = new List<OpportunityContactRole>();
        for (Integer i = 0; i < BULK_N; i++) {
            roles.add(new OpportunityContactRole(
                OpportunityId = deals[i].Id,
                ContactId = brokers[i].Id,
                Role = 'Broker',
                IsPrimary = true
            ));
        }
        insert roles;

        Set<Id> dealIds = new Map<Id, Opportunity>(deals).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<OpportunityContactRole> rows = OpportunityContactRoleSelector.selectByOpportunityIds(dealIds);
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(), 'All 251 role rows must come back');
        Assert.areEqual(1, after - before,
            'ONE query for 251 Opportunities. This is the contract that keeps LeadConvertService at '
            + '2 SOQL per invocation regardless of batch size — a per-record read would spend 251 and '
            + 'exhaust the transaction limit at 100');

        Set<Id> distinctOpps = new Set<Id>();
        for (OpportunityContactRole r : rows) {
            distinctOpps.add(r.OpportunityId);
            Assert.isNotNull(r.ContactId, 'Every returned row carries its ContactId match key');
        }
        Assert.areEqual(BULK_N, distinctOpps.size(), 'One row per distinct Opportunity, none dropped');
    }
}
