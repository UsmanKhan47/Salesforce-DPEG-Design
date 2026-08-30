/**
 * Tests for ContactSelector (P4, Module B2 — Property Management; standard object).
 *
 * Covers the single relocated query:
 *   - selectBrokersOrderedByName : the broker filter, ORDER BY Name, Broker_Firm__c
 *     population, the no-brokers empty result, AND the standard-object USER_MODE proof
 *     required by design §7.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════
 * 🔴 2026-08-20 — THE BROKER DEFINITION MOVED, AND FOUR FIXTURES IN THIS CLASS INVERTED
 * ═══════════════════════════════════════════════════════════════════════════════════
 * A broker is now a Contact on the `Contact.Broker` RECORD TYPE, not `Is_Broker__c = true`.
 *
 * 🔴 `TestDataFactory.createContacts` / `createContact` ARE NOT NON-BROKER FIXTURES. They
 * stamp the Broker record type (and have since 2026-08-10); they only leave `Is_Broker__c`
 * at its false default. Four tests here used them as "a non-broker must be excluded" or
 * "no brokers exist" controls, which worked ONLY because the checkbox was the definition:
 *
 *   selectBrokersOrderedByName_returnsOnlyBrokersOrderedByName        2 rows -> 3
 *   selectBrokersOrderedByName_noBrokers_returnsEmpty                 0 rows -> 3
 *   selectBrokersRankedByClosedVolume_ranksByVolumeThenName_...       3 rows -> 4
 *   selectBrokersRankedByClosedVolume_noBrokers_returnsEmpty          0 rows -> 3
 *   selectBrokerPriorityByEmailSystem_nonBrokerWithSameEmail_excluded null -> a row
 *
 * All five now use `TestDataFactory.createNonBrokerContacts` / `createNonBrokerContact`.
 * EVERY ORIGINAL ASSERTION SURVIVED UNCHANGED — the fixtures were wrong, the expectations
 * were not, and these are the suite's only proofs that the broker selectors EXCLUDE
 * non-brokers. Do not repoint any of them back at `createContact(s)`.
 *
 * ⚠ NOT affected, checked individually: every `selectByEmails_*` and `selectEarliestBy*`
 * test (they assert presence or scope, not broker exclusion) and
 * `selectByEmails_251DistinctEmailsWithAccounts_returnsAll`, which DEPENDS on the factory's
 * Broker stamp because selectByEmails has filtered the record type since 2026-08-10.
 *
 * USER_MODE PROOF NUANCE (design mismatch flagged to the orchestrator): unlike the
 * Task standard-object proof, this query selects the CUSTOM Contact.Broker_Firm__c.
 * (⚠ 2026-08-20: this also read "and filters the CUSTOM Contact.Is_Broker__c" — retracted;
 * the predicate is now a non-FLS RecordType traversal, so the SELECT list carries the whole
 * FLS exposure.) A bare Standard User has no FLS on
 * those custom fields, so USER_MODE would throw. The runAs proof therefore assigns
 * DPEG_Contact_Edit, the layer-3 module set that owns broker Contact access —
 * mirroring the real broker-options persona, and confirming USER_MODE returns rows
 * once the grants are present. (This read DPEG_Acquisitions until 2026-08-10; that
 * monolith was retired and it was never the ONLY grantor — DPEG_Contact_Edit and
 * DPEG_Contact_View both carry these fields.)
 *
 * @see force-app/main/default/classes/TaskSelectorTest.cls (P4 standard-object template)
 * @see agent-output/p4-selector-design.md (§3 #19, §5, §7)
 */
@isTest
private class ContactSelectorTest {

    private static final Integer BULK_N = 251;

    // ─────────────────────────────────────────────────────────────────────────
    // selectBrokersOrderedByName
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectBrokersOrderedByName_returnsOnlyBrokersOrderedByName() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(2, null, false);
        brokers[0].LastName = 'Zeta';                 // Name 'Test Zeta' -> sorts last
        brokers[0].Broker_Firm__c = 'Zeta Realty';
        brokers[1].LastName = 'Alpha';                // Name 'Test Alpha' -> sorts first
        brokers[1].Broker_Firm__c = 'Alpha Realty';
        insert brokers;
        // A non-broker Contact must be excluded.
        // ⚠ 2026-08-20: was `createContact(null, true)`, on the belief that a plain factory Contact
        // is a non-broker. IT IS NOT — createContacts stamps the Broker record type. That was
        // invisible while Is_Broker__c was the definition and became a false positive the moment it
        // stopped being. See TestDataFactory.createNonBrokerContacts.
        TestDataFactory.createNonBrokerContact(null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersOrderedByName();
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            'Only Contact.Broker record-type Contacts are returned; the non-broker Contact is excluded');
        Assert.areEqual('Test Alpha', rows[0].Name, 'ORDER BY Name returns the alphabetically-first broker first');
        Assert.areEqual('Alpha Realty', rows[0].Broker_Firm__c, 'Broker_Firm__c is selected for the option label');
        Assert.areEqual('Test Zeta', rows[1].Name, 'The second broker sorts after the first by Name');
    }

    /**
     * ⚠ FIXTURE REPOINTED 2026-08-20 — READ BEFORE "SIMPLIFYING" IT BACK.
     *
     * This test used `TestDataFactory.createContacts(3, null, true)` as its "only non-broker
     * Contacts exist" fixture. That was WRONG THE WHOLE TIME and merely undetectable: the factory
     * has stamped the `Contact.Broker` record type on every Contact it produces since 2026-08-10,
     * and only left `Is_Broker__c` at its false default. While the checkbox WAS the broker
     * definition the fixture behaved as intended by accident; when the definition moved to the
     * record type the same three rows became BROKERS and this assertion inverted from 0 to 3.
     *
     * 🔴 THE ASSERTION IS DELIBERATELY UNCHANGED. It is one of only two proofs in this suite that
     * the broker selectors return an empty list rather than everything when no broker exists, and
     * weakening it to match the new fixture behaviour would have deleted the proof instead of
     * fixing the fixture. The FIXTURE was wrong, not the expectation.
     */
    @isTest
    static void selectBrokersOrderedByName_noBrokers_returnsEmpty() {
        // Only non-broker Contacts exist — off the Broker record type AND unflagged, so they fail
        // both the retired and the current definition.
        TestDataFactory.createNonBrokerContacts(3, null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersOrderedByName();
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'With no broker Contacts the selector returns an empty list, not null');
    }

    /**
     * Standard-object USER_MODE proof (design §5/§7). A freshly created Standard
     * User granted the DPEG_Contact_Edit permission set (which grants Contact CRUD
     * plus FLS on the custom Contact.Is_Broker__c / Broker_Firm__c this query touches)
     * reads broker rows under WITH USER_MODE. The broker Contacts are inserted INSIDE
     * runAs so the Standard User owns them (removing sharing as a variable and isolating
     * the FLS question). The User + PermissionSetAssignment DML is isolated in its own
     * runAs block to avoid MIXED_DML_OPERATION with the non-setup Contact DML.
     *
     * ⚠ This named DPEG_Acquisitions until 2026-08-10, when that legacy monolith was
     * retired (docs/permission-set-retirement-runbook.md). The query below resolves a
     * permission set BY NAME, so deleting the named set fails this test with
     * "System.QueryException: List has no rows for assignment to SObject" rather than
     * with an FLS assertion — i.e. the failure does NOT look like a permission problem.
     * DPEG_Contact_Edit is the conformant successor: it is the layer-3 module set that
     * owns broker Contact access, so it is the correct grant to prove FLS with here.
     * User granted the DPEG_Acquisitions permission set (which grants FLS on the
     * custom Contact.Is_Broker__c / Broker_Firm__c this query touches) reads broker
     * rows under WITH USER_MODE. The broker Contacts are inserted INSIDE runAs so the
     * Standard User owns them (removing sharing as a variable and isolating the FLS
     * question). The User + PermissionSetAssignment DML is isolated in its own runAs
     * block to avoid MIXED_DML_OPERATION with the non-setup Contact DML.
     *
     * ⚠ ALSO GRANTS DPEG_Contact_Edit (added 2026-08-10, fix round 1). TestDataFactory now
     * stamps every factory Contact onto the Contact.Broker record type (IR/Acquisitions
     * segregation, Task 3), and DPEG_Acquisitions alone does not carry that record type's
     * visibility - only DPEG_Contact_Edit / DPEG_Contact_View do (Task 2). Without this grant
     * TestDataFactory.recordTypeId's isAvailable() guard degrades this persona to an unstamped
     * (default-record-type) Contact rather than throwing - but that would silently defeat this
     * test's own stated intent, "mirrors the real broker-options persona": a persona reading the
     * broker-options list must be able to see and create Broker-typed Contacts in the first
     * place, so DPEG_Contact_Edit belongs on this fixture on the merits, independent of the
     * factory change that surfaced its absence.
     */
    @isTest
    static void selectBrokersOrderedByName_standardUserWithGrants_userModeReturnsRows() {
        User standardUser = buildStandardUser();
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DPEG_Contact_Edit' LIMIT 1].Id;
        Id acqPermSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DPEG_Acquisitions' LIMIT 1].Id;
        Id contactEditPermSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DPEG_Contact_Edit' LIMIT 1].Id;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert standardUser;
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = standardUser.Id, PermissionSetId = acqPermSetId),
                new PermissionSetAssignment(AssigneeId = standardUser.Id, PermissionSetId = contactEditPermSetId)
            };
        }

        Test.startTest();
        System.runAs(standardUser) {
            // Insert 2 broker Contacts as the Standard User (side effect is the point;
            // the selector re-queries them), exercising create + FLS end-to-end.
            TestDataFactory.createBrokerContacts(2, null, true);

            List<Contact> rows = ContactSelector.selectBrokersOrderedByName();

            Assert.areEqual(2, rows.size(),
                'A Standard User granted DPEG_Contact_Edit reads broker Contacts under WITH USER_MODE');
            Assert.isNotNull(rows[0].Broker_Firm__c,
                'Broker_Firm__c (custom, FLS-controlled) is readable under USER_MODE once DPEG_Contact_Edit grants it');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectBrokersRankedByClosedVolume  (BrokerController — Broker Hub)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectBrokersRankedByClosedVolume_ranksByVolumeThenName_excludesNonBrokers() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(3, null, false);
        brokers[0].LastName = 'Zulu';  brokers[0].Closed_Volume__c = 10000000; brokers[0].Active_Listings__c = 2;
        brokers[1].LastName = 'Bravo'; brokers[1].Closed_Volume__c = 30000000; brokers[1].Active_Listings__c = 8;
        // Alpha ties Bravo on Closed_Volume__c so the Name ASC tiebreak decides order.
        brokers[2].LastName = 'Alpha'; brokers[2].Closed_Volume__c = 30000000; brokers[2].Active_Listings__c = 4;
        insert brokers;
        // A non-broker Contact must be excluded. ⚠ 2026-08-20: was `createContact(null, true)` —
        // see the identical correction on selectBrokersOrderedByName_returnsOnlyBrokersOrderedByName
        // above. A plain factory Contact carries the Broker record type and is NOT a non-broker.
        TestDataFactory.createNonBrokerContact(null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersRankedByClosedVolume();
        Test.stopTest();

        Assert.areEqual(3, rows.size(),
            'Only Contact.Broker record-type Contacts are returned; the non-broker Contact is excluded');
        Assert.areEqual('Test Alpha', rows[0].Name,
            'Closed_Volume__c DESC then Name ASC: Alpha wins the 30M tie over Bravo on Name');
        Assert.areEqual('Test Bravo', rows[1].Name, 'Bravo is the second of the two 30M brokers');
        Assert.areEqual('Test Zulu', rows[2].Name, 'The 10M broker ranks last by Closed_Volume__c DESC');
        Assert.areEqual(30000000, rows[0].Closed_Volume__c, 'Closed_Volume__c is selected for the header stats');
        Assert.areEqual(4, rows[0].Active_Listings__c, 'Active_Listings__c is selected for the header stats');
    }

    /**
     * ⚠ FIXTURE REPOINTED 2026-08-20 for the same reason, and with the same refusal to weaken the
     * assertion, as selectBrokersOrderedByName_noBrokers_returnsEmpty above. These two are the
     * suite's only proofs that a broker selector returns EMPTY rather than EVERYTHING when the org
     * holds no brokers; both had been resting on a fixture that silently produced brokers.
     */
    @isTest
    static void selectBrokersRankedByClosedVolume_noBrokers_returnsEmpty() {
        TestDataFactory.createNonBrokerContacts(3, null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersRankedByClosedVolume();
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'With no broker Contacts the selector returns an empty list, not null');
    }

    @isTest
    static void selectBrokersRankedByClosedVolume_251Brokers_returnsAll() {
        // A 251-record standard-object insert can trip an org duplicate rule; the
        // factory makes Email unique, and AllowSave is set as defence-in-depth
        // (guardrail from prior selector waves — see LeadSelectorTest).
        List<Contact> brokers = TestDataFactory.createBrokerContacts(BULK_N, null, false);
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.insert(brokers, dml);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersRankedByClosedVolume();
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(),
            'All 251 broker Contacts are returned at data volume (bulk-safe single query)');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectTopBrokersByActiveListings  (BrokerController — Broker Hub top list)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectTopBrokersByActiveListings_filtersZeroListings_ranksByActiveListings() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(4, null, false);
        brokers[0].LastName = 'Eight'; brokers[0].Active_Listings__c = 8; brokers[0].Closed_Volume__c = 24000000;
        brokers[0].Broker_Firm__c = 'CBRE';
        brokers[1].LastName = 'Five';  brokers[1].Active_Listings__c = 5; brokers[1].Closed_Volume__c = 18000000;
        brokers[2].LastName = 'Two';   brokers[2].Active_Listings__c = 2; brokers[2].Closed_Volume__c = 6000000;
        brokers[3].LastName = 'Zero';  brokers[3].Active_Listings__c = 0; brokers[3].Closed_Volume__c = 0;
        insert brokers;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectTopBrokersByActiveListings(6);
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'Active_Listings__c > 0 excludes the zero-listing broker');
        Assert.areEqual(8, rows[0].Active_Listings__c, 'Highest Active_Listings__c first');
        Assert.areEqual(2, rows[2].Active_Listings__c, 'Lowest of the three last');
        Assert.areEqual('CBRE', rows[0].Broker_Firm__c, 'Broker_Firm__c is selected for the top-broker card');
    }

    @isTest
    static void selectTopBrokersByActiveListings_respectsMaxRows() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(4, null, false);
        brokers[0].LastName = 'Ten';  brokers[0].Active_Listings__c = 10; brokers[0].Closed_Volume__c = 40000000;
        brokers[1].LastName = 'Nine'; brokers[1].Active_Listings__c = 9;  brokers[1].Closed_Volume__c = 30000000;
        brokers[2].LastName = 'Six';  brokers[2].Active_Listings__c = 6;  brokers[2].Closed_Volume__c = 20000000;
        brokers[3].LastName = 'Four'; brokers[3].Active_Listings__c = 4;  brokers[3].Closed_Volume__c = 10000000;
        insert brokers;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectTopBrokersByActiveListings(2);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'LIMIT :maxRows caps the result at 2 rows');
        Assert.areEqual(10, rows[0].Active_Listings__c, 'The top broker by Active_Listings__c is first');
        Assert.areEqual(9, rows[1].Active_Listings__c, 'The second-highest is second; the rest are cut by the LIMIT');
    }

    @isTest
    static void selectTopBrokersByActiveListings_nullOrNonPositiveMaxRows_returnsEmpty() {
        TestDataFactory.createBrokerContacts(2, null, true);

        Test.startTest();
        List<Contact> nullRows = ContactSelector.selectTopBrokersByActiveListings(null);
        List<Contact> zeroRows = ContactSelector.selectTopBrokersByActiveListings(0);
        Test.stopTest();

        Assert.areEqual(0, nullRows.size(), 'A null maxRows short-circuits to an empty list without querying');
        Assert.areEqual(0, zeroRows.size(), 'A non-positive maxRows short-circuits to an empty list without querying');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GuestReads.selectBrokerPriorityByEmailSystem
    //   (BrokerPortalController — guest; SYSTEM_MODE + without sharing)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Lives in the `without sharing` GuestReads inner class (all-records guest read,
    // preserving the original controller behavior); SYSTEM_MODE additionally bypasses
    // FLS. These tests run as the default (privileged) test user and prove the query
    // shape (email trim, Is_Broker__c filter, field population, blank guard). The
    // guest sharing/ownership model itself is out of scope for a unit test — it needs
    // the P3 guest-sharing spike verified before portal promotion (see the report).
    //
    // ⚠ 2026-08-20: "the Is_Broker__c filter" above is retracted — this query now filters
    // `RecordType.DeveloperName = 'Broker'`. On the live org that swap takes it from matching
    // ZERO rows to matching the real broker roster, so the exclusion test below stopped being
    // a formality and became the containment proof for an internet-reachable read.

    @isTest
    static void selectBrokerPriorityByEmailSystem_matchingBroker_returnsPriority() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.Email = 'known.broker@example.com';
        broker.Broker_Priority__c = 'High';
        insert broker;

        Test.startTest();
        Contact result = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem('  known.broker@example.com  ');
        Test.stopTest();

        Assert.isNotNull(result, 'A broker Contact with the given email resolves');
        Assert.areEqual('High', result.Broker_Priority__c, 'Broker_Priority__c is populated for the caller to copy');
    }

    /**
     * 🔴 THE HIGHEST-VALUE EXCLUSION PROOF IN THIS CLASS — it guards the only UNAUTHENTICATED read
     * in ContactSelector. This is the assertion that says a guest supplying an arbitrary email
     * cannot pull a non-broker Contact's `Broker_Priority__c` back out of the org.
     *
     * ⚠ FIXTURE REPOINTED 2026-08-20, and this one was NOT on the change brief's list of inverting
     * tests — it was found by tracing `createContact` (singular) through to `createContacts`, which
     * stamps the Broker record type. It would have inverted exactly like the two `noBrokers_*`
     * tests: the "plain" Contact becomes a broker, the guest read matches it, and `Assert.isNull`
     * fails. Had the assertion been "fixed" to match, the suite would have lost its only proof of
     * containment on the guest path.
     */
    @isTest
    static void selectBrokerPriorityByEmailSystem_nonBrokerWithSameEmail_excluded() {
        // A genuinely non-broker Contact (off the Broker record type AND unflagged) with the same
        // email must not match — the record-type predicate excludes it.
        Contact plain = TestDataFactory.createNonBrokerContact(null, false);
        plain.Email = 'plain.contact@example.com';
        insert plain;

        Test.startTest();
        Contact result = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem('plain.contact@example.com');
        Test.stopTest();

        Assert.isNull(result,
            'A non-broker Contact is excluded by RecordType.DeveloperName = \'Broker\' — a guest '
            + 'must not be able to read priority off an arbitrary Contact by guessing its email');
    }

    @isTest
    static void selectBrokerPriorityByEmailSystem_noMatch_returnsNull() {
        Test.startTest();
        Contact result = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem('nobody@example.com');
        Test.stopTest();

        Assert.isNull(result, 'An unknown email returns null (caller defaults to Standard)');
    }

    @isTest
    static void selectBrokerPriorityByEmailSystem_blankInput_returnsNull() {
        Test.startTest();
        Contact nullResult = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem(null);
        Contact blankResult = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem('   ');
        Test.stopTest();

        Assert.isNull(nullResult, 'Null input returns null');
        Assert.isNull(blankResult, 'Blank input returns null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectEarliestByAccountId  (BrokerFirmController — sidebar broker person)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectEarliestByAccountId_returnsContactScopedToAccount() {
        // Two same-City/State Accounts AND two similar Contacts each trip an org
        // duplicate rule on the second insert; bypass both (defence-in-depth pattern
        // from prior waves).
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Account firmA = TestDataFactory.createAccount(false);
        Account firmB = TestDataFactory.createAccount(false);
        Database.insert(new List<Account>{ firmA, firmB }, dml);
        Contact contactA = TestDataFactory.createContact(firmA.Id, false);
        Contact contactB = TestDataFactory.createContact(firmB.Id, false);  // different firm — must not be returned
        Database.insert(new List<Contact>{ contactA, contactB }, dml);

        Test.startTest();
        Contact result = ContactSelector.selectEarliestByAccountId(firmA.Id);
        Test.stopTest();

        Assert.isNotNull(result, 'A firm Account with a linked Contact resolves a broker person');
        Assert.areEqual(contactA.Id, result.Id, 'Only the Contact under the requested Account is returned');
        Assert.isNotNull(result.Name, 'Name must be populated for the sidebar broker name');
    }

    @isTest
    static void selectEarliestByAccountId_manyContacts_returnsSingleRow() {
        Account firm = TestDataFactory.createAccount(true);
        TestDataFactory.createContacts(BULK_N, firm.Id, true);

        Test.startTest();
        Contact result = ContactSelector.selectEarliestByAccountId(firm.Id);
        Test.stopTest();

        Assert.isNotNull(result, 'LIMIT 1 returns a single Contact even with 251 under the Account');
        Assert.isNotNull(result.Name, 'Name is populated on the returned row');
    }

    @isTest
    static void selectEarliestByAccountId_noContact_returnsNull() {
        Account firm = TestDataFactory.createAccount(true);

        Test.startTest();
        Contact result = ContactSelector.selectEarliestByAccountId(firm.Id);
        Test.stopTest();

        Assert.isNull(result, 'An Account with no linked Contact returns null');
    }

    @isTest
    static void selectEarliestByAccountId_nullInput_returnsNull() {
        Test.startTest();
        Contact result = ContactSelector.selectEarliestByAccountId(null);
        Test.stopTest();

        Assert.isNull(result, 'Null input returns null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectByEmails  (LeadConvertMatchService — Smart Lead Conversion, 2026-08-02)
    //
    // The consumer's own suite (LeadConvertMatchServiceTest) exercises this query through
    // matchForConversion end to end, including the D2 oldest-wins tie-break. These are the
    // direct selector-level proofs of the two contracts that class depends on: the
    // AccountId != null filter, and the null/empty-input short-circuit that no existing test
    // (at the selector OR the service layer) reaches — every LeadConvertMatchServiceTest
    // fixture supplies a non-blank Lead.Email, so the emails set handed to this method is
    // never actually empty in that suite.
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectByEmails_exactEmailMatchWithAccount_returnsTheContact() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createContact(firm.Id, false);
        broker.Email = 'selector.broker@firm.invalid';
        insert broker;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ 'selector.broker@firm.invalid' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The exactly-matching, account-having Contact should be returned');
        Assert.areEqual(broker.Id, rows[0].Id, 'The matching Contact should be returned');
        Assert.areEqual(firm.Id, rows[0].AccountId,
            'AccountId is selected — it is what the caller carries forward as the conversion target Account');
        Assert.isNotNull(rows[0].CreatedDate, 'CreatedDate is selected — it drives the D2 oldest-wins ordering');
    }

    /**
     * `AccountId != null` IS THE FILTER, NOT A DEFENSIVE CHECK (ContactSelector's own header).
     * An orphan Contact sharing the same email must never come back, or the caller would hand
     * Database.LeadConvert.setContactId a Contact with no Account, which convertLead rejects.
     */
    @isTest
    static void selectByEmails_matchingContactWithNoAccount_isExcluded() {
        Contact orphan = TestDataFactory.createContact(null, false);
        orphan.Email = 'orphan.selector@firm.invalid';
        insert orphan;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ 'orphan.selector@firm.invalid' });
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'An account-less Contact must never be returned — Database.LeadConvert.setContactId requires an Account');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectBrokerByEmailForIntake  (WS8 intake broker match, 2026-08-30)
    //
    // The AUTOMATION twin of selectByEmails above. Same question, different trust model:
    // SYSTEM_MODE because the caller is the Email Service context user inside a Queueable that
    // owns the broker's Lead and registry claim, where a USER_MODE throw would not degrade a
    // button click — it would abort the transaction. Singular + LIMIT 1, because the sender is
    // ONE email-level fact resolved ONCE per email.
    //
    // ⚠ NO 251-ROW TEST HERE, DELIBERATELY, AND FOR THE SAME REASON THE BULK_N TESTS ABOVE ARE
    // SHAPED AS THEY ARE: this method takes a SINGLE address and returns AT MOST ONE ROW by
    // construction (`LIMIT 1`). There is no collection to bulkify and no batch boundary to cross,
    // so 251 rows would exercise no additional code path. Its VOLUME contract — one query per
    // EMAIL at MAX_PROPERTIES properties — lives where the loop is, in
    // ExtractAddressQueueableTest.execute_tenPropertyEmail_resolvesTheBrokerExactlyOnceAndMovesNoBudget.
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectBrokerByEmailForIntake_exactMatchWithAccount_returnsTheContactAndItsAccount() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createBrokerContacts(1, firm.Id, false)[0];
        broker.Email = 'intake.broker@firm.invalid';
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ broker });

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokerByEmailForIntake('intake.broker@firm.invalid');
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The exactly-matching broker Contact with an Account is returned');
        Assert.areEqual(broker.Id, rows[0].Id, 'and it is the right row');
        Assert.areEqual(firm.Id, rows[0].AccountId,
            '🔴 AccountId IS SELECTED, AND THAT IS WHY THIS FEATURE COSTS ONE QUERY RATHER THAN TWO. '
            + 'The firm is resolved by this same statement; no AccountSelector round trip exists or '
            + 'is wanted');
    }

    /**
     * 🔴 THE ACCOUNT-LESS CONTACT, EXCLUDED BY PREDICATE RATHER THAN BY SHARING.
     *
     * Two independent reasons, both recorded at the method: (1) an orphan cannot be a conversion
     * target, so stamping it into `Lead.Broker__c` would hand `Database.convertLead` a pair it
     * refuses; (2) a Contact with no AccountId is visible only to its OWNER whatever the OWD says
     * (Contact OWD is ControlledByParent and a parentless Contact has no parent), so under
     * `with sharing` the same broker email would link for one principal and not another. The
     * filter converts that coin-flip into a rule.
     *
     * ⚠ THE FIXTURE IS OWNED BY THE TEST-RUNNING USER AND IS THEREFORE VISIBLE TO IT — so sharing
     * cannot be what makes this pass. Only the `AccountId != null` predicate can.
     */
    @isTest
    static void selectBrokerByEmailForIntake_accountLessBroker_isExcluded() {
        Contact orphan = TestDataFactory.createBrokerContacts(1, null, false)[0];
        orphan.Email = 'intake.orphan@firm.invalid';
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ orphan });
        Assert.isNull(orphan.AccountId, 'Precondition: the fixture really is account-less');

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokerByEmailForIntake('intake.orphan@firm.invalid');
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'An account-less broker Contact never matches at intake — deterministically, for every '
            + 'principal, rather than depending on who owns the row');
    }

    /**
     * RECORD-TYPE SCOPE, identical to selectByEmails (IR segregation, 2026-08-10). One email
     * address shared between a broker and an investor must never attach an acquisition Lead to an
     * IR Contact.
     */
    @isTest
    static void selectBrokerByEmailForIntake_nonBrokerRecordType_isExcluded() {
        // 🔴 THE PARENT ACCOUNT MUST BE Investor_Entity, NOT THE FACTORY'S DEFAULT Broker_Firm.
        // MEASURED 2026-08-30 (check-only 0Afiw000000TkTr): parenting an Investor Contact to a
        // Broker_Firm Account throws FIELD_CUSTOM_VALIDATION_EXCEPTION on the
        // `Record_Type_Matches_Account` rule — which is a SECURITY rule, not hygiene (Contact OWD
        // is ControlledByParent, so a mismatched parent leaks the Contact to the wrong team).
        //
        // ⚠ AND THE FIXTURE MUST HAVE AN ACCOUNT AT ALL, or this test would go VACUOUS: an
        // account-less Contact is already excluded by the `AccountId != null` filter, so it would
        // pass for the wrong reason and stop proving anything about the RECORD TYPE.
        Account entity = TestDataFactory.createAccounts(1, false)[0];
        entity.RecordTypeId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('Investor_Entity').getRecordTypeId();
        insert entity;
        Contact investor = TestDataFactory.createNonBrokerContacts(1, entity.Id, false)[0];
        investor.Email = 'intake.investor@firm.invalid';
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ investor });
        Assert.isNotNull([SELECT AccountId FROM Contact WHERE Id = :investor.Id].AccountId,
            'Precondition: the fixture HAS an Account, so only the record-type filter can exclude it');

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokerByEmailForIntake('intake.investor@firm.invalid');
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'A Contact that is not on the Contact.Broker record type must not be linked to an '
            + 'acquisition Lead, even when the email matches exactly');
    }

    /** SOQL Email comparison is case-insensitive by default — the same platform behaviour
     *  selectByEmails relies on, re-proven here because this method uses `=` not `IN`. */
    @isTest
    static void selectBrokerByEmailForIntake_caseInsensitiveMatch_stillReturnsTheContact() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createBrokerContacts(1, firm.Id, false)[0];
        broker.Email = 'Intake.Mixed.Case@Firm.Invalid';
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ broker });

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokerByEmailForIntake('intake.mixed.case@firm.invalid');
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'A differently-cased sender address must still match — do NOT add LOWER(), which is '
            + 'invalid on this field and unnecessary');
    }

    /**
     * ⚠ THE EMPTY-LIST CONTRACT IS LOAD-BEARING, NOT TIDINESS. The caller's fail-soft catches
     * broadly; if this method were ever refactored to a single-row assignment
     * (`Contact c = [SELECT ...];`), the ORDINARY no-match case would throw QueryException, be
     * swallowed as a failure, and turn "this broker is new" into a permanently, invisibly disabled
     * feature. Blank input must also short-circuit WITHOUT querying — a blank sender address is a
     * normal state on an unaddressable email.
     */
    @isTest
    static void selectBrokerByEmailForIntake_noMatchOrBlankInput_returnsEmptyWithoutThrowing() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Contact> blank = ContactSelector.selectBrokerByEmailForIntake('   ');
        List<Contact> nullInput = ContactSelector.selectBrokerByEmailForIntake(null);
        Integer afterShortCircuit = Limits.getQueries();
        List<Contact> noMatch =
            ContactSelector.selectBrokerByEmailForIntake('nobody.at.all@firm.invalid');
        Test.stopTest();

        Assert.areEqual(0, blank.size(), 'A blank address returns an EMPTY LIST, never null, never a throw');
        Assert.areEqual(0, nullInput.size(), 'and so does null');
        Assert.areEqual(before, afterShortCircuit,
            'and NEITHER costs a query — the short-circuit is above the SOQL, so an unaddressable '
            + 'sender spends nothing against a PINNED per-email query budget');
        Assert.areEqual(0, noMatch.size(),
            'A genuine no-match is an EMPTY LIST too. If this method is ever rewritten as a '
            + 'single-row assignment it will throw here instead, and the caller will silently '
            + 'record a permanent degrade');
    }

    /** SOQL Email comparison is case-insensitive by default; see AccountSelector's identical note. */
    @isTest
    static void selectByEmails_caseInsensitiveMatch_stillReturnsTheContact() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createContact(firm.Id, false);
        broker.Email = 'Mixed.Case.Selector@Firm.Invalid';
        insert broker;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ 'mixed.case.selector@firm.invalid' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'A differently-cased candidate must still match');
        Assert.areEqual(broker.Id, rows[0].Id, 'The matching Contact should be returned');
    }

    /**
     * D2 — oldest wins, `ORDER BY CreatedDate ASC, Id ASC`, mirroring
     * AccountSelectorTest.selectByNames_multipleRowsSameName_ordersOldestFirst and
     * LeadConvertMatchServiceTest.matchForConversion_multipleContactsSameEmail_oldestWins: the
     * older Contact is inserted SECOND (higher Id) and then aged, so an Id-only or
     * insert-order-only sort would return the wrong row first.
     */
    @isTest
    static void selectByEmails_multipleRowsSameEmail_ordersOldestFirst() {
        // Both seeds are duplicate-shaped and must allow-save — the same defence-in-depth already
        // applied inline by a prior wave in selectEarliestByAccountId_accountWithContacts_* above,
        // now consolidated into TestDataFactory.insertAllowingDuplicates:
        //   • the two Accounts, because createAccounts stamps every row BillingCity='Houston' /
        //     BillingState='TX' and the standard Account rule matches fuzzy-name + city/state, so
        //     ANY two factory Accounts in one transaction match each other;
        //   • the two Contacts, because sharing an Email is the entire point of this tie-break.
        // Neither weakens the assertions: the rows, Ids and CreatedDates are untouched.
        Account firmA = TestDataFactory.createAccount(false);
        Account firmB = TestDataFactory.createAccount(false);
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ firmA, firmB });

        String sharedEmail = 'ambiguous.selector@firm.invalid';
        Contact newer = TestDataFactory.createContact(firmA.Id, false);
        newer.Email = sharedEmail;
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ newer }); // first -> lower Id, recent CreatedDate
        Contact older = TestDataFactory.createContact(firmB.Id, false);
        older.Email = sharedEmail;
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ older }); // second -> higher Id
        Test.setCreatedDate(older.Id, Datetime.now().addYears(-2));

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ sharedEmail });
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both same-email Contacts should be returned — no LIMIT here, the caller applies it');
        Assert.areEqual(older.Id, rows[0].Id,
            'CreatedDate ASC must put the OLDER row first even though it has the HIGHER Id');
        Assert.areEqual(newer.Id, rows[1].Id, 'The newer row sorts second');
    }

    /**
     * IR segregation (2026-08-10, Task 6). The broker and investor populations are disjoint by
     * policy, so this pins the STRUCTURAL guarantee: even a fabricated shared-email collision
     * between a broker and an investor Contact must not surface an IR Contact as a lead-conversion
     * match target — see the RECORD TYPE SCOPE note on ContactSelector.selectByEmails's ApexDoc.
     */
    @isTest
    static void selectByEmails_investorContact_isExcluded() {
        Account investorAccount = TestDataFactory.createAccount(false);
        investorAccount.RecordTypeId = [SELECT Id FROM RecordType
            WHERE SobjectType = 'Account' AND DeveloperName = 'Investor_Entity' LIMIT 1].Id;
        insert investorAccount;

        Contact investor = TestDataFactory.createContact(investorAccount.Id, false);
        investor.Email = 'shared.address@example.invalid';
        investor.RecordTypeId = [SELECT Id FROM RecordType
            WHERE SobjectType = 'Contact' AND DeveloperName = 'Investor' LIMIT 1].Id;
        insert investor;

        Test.startTest();
        List<Contact> matched = ContactSelector.selectByEmails(
            new Set<String>{ 'shared.address@example.invalid' });
        Test.stopTest();

        Assert.areEqual(0, matched.size(),
            'An investor Contact must never be a lead-conversion match target - attaching an '
            + 'acquisition deal to an IR Contact would drag it across the security boundary.');
    }

    @isTest
    static void selectByEmails_noMatch_returnsEmpty() {
        Account firm = TestDataFactory.createAccount(true);
        TestDataFactory.createContact(firm.Id, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ 'nobody.matches@firm.invalid' });
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'An email nothing matches returns an empty list, not null');
    }

    /**
     * GAP CLOSED (unit-testing agent pass, 2026-08-03). Neither this selector's own suite nor
     * LeadConvertMatchServiceTest previously exercised this branch: every match-service fixture
     * supplies a non-blank Lead.Email, so `emails` handed to selectByEmails is never actually
     * empty anywhere else in the app's test suite.
     */
    @isTest
    static void selectByEmails_nullOrEmptyInput_returnsEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Contact> forNull = ContactSelector.selectByEmails(null);
        List<Contact> forEmpty = ContactSelector.selectByEmails(new Set<String>());
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null email set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty email set short-circuits to an empty list, not null');
        Assert.areEqual(0, after - before, 'Neither call should spend a query — the empty-set guard runs before the SOQL');
    }

    /**
     * Bulk-safety at data volume, per this repo's standing selector-layer convention — see
     * selectBrokersRankedByClosedVolume_251Brokers_returnsAll above — independent of, and in
     * addition to, the SERVICE-level 251 proof in
     * LeadConvertMatchServiceTest.matchForConversion_at251Leads_isBulkSafe.
     */
    @isTest
    static void selectByEmails_251DistinctEmailsWithAccounts_returnsAll() {
        Account firm = TestDataFactory.createAccount(true);
        List<Contact> brokers = TestDataFactory.createContacts(BULK_N, firm.Id, true);
        Set<String> emails = new Set<String>();
        for (Contact c : brokers) {
            emails.add(c.Email);
        }

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(emails);
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(), 'All 251 distinctly-emailed, account-having Contacts must be returned in one query');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectBrokerLabelsByIds
    //   (DispositionBrokerStampService — off-market broker lookup, 2026-08-20; WITH SYSTEM_MODE,
    //   automation read inside a Disposition__c before-trigger — see that selector method's ApexDoc)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // No dedicated "zero-Contact-grant Standard User" SYSTEM_MODE proof here, unlike
    // selectBrokersOrderedByName's USER_MODE proof above — that pattern needs the running user to
    // OWN or otherwise see the Contact under sharing (SYSTEM_MODE lifts CRUD/FLS, never sharing;
    // see the method's own "SHARING IS A SEPARATE QUESTION" note), which is a materially different
    // proof from "no permission set is required". These three tests instead mirror this repo's
    // standing SYSTEM_MODE selector convention (DispositionSelector.selectStageAndTypeByIds and
    // siblings): basic field population + exclusion, the null/empty no-query contract, and the
    // bulk-251-one-query proof — run as the privileged default test user throughout.

    @isTest
    static void selectBrokerLabelsByIds_returnsNameAndFirmForRequestedIds() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(2, null, true);
        // A broker Contact NOT in the requested set must not be returned. LastName is
        // differentiated from the 'Contact 0' / 'Contact 1' pair above — an un-differentiated
        // third insert collides with the org's standard duplicate rule (same shape as
        // selectBrokersRankedByClosedVolume_ranksByVolumeThenName_excludesNonBrokers above).
        Contact other = TestDataFactory.createBrokerContact(null, false);
        other.LastName = 'Excluded';
        insert other;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokerLabelsByIds(
            new Set<Id>{ brokers[0].Id, brokers[1].Id });
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Only the requested Contacts are returned');
        Map<Id, Contact> byId = new Map<Id, Contact>(rows);
        Assert.isTrue(byId.containsKey(brokers[0].Id), 'The first requested broker is returned');
        Assert.isTrue(byId.containsKey(brokers[1].Id), 'The second requested broker is returned');
        Assert.isFalse(byId.containsKey(other.Id), 'A broker NOT in the requested set must be excluded');
        Assert.isNotNull(byId.get(brokers[0].Id).Name, 'Name is selected — the caller composes the label from it');
        Assert.areEqual(brokers[0].Broker_Firm__c, byId.get(brokers[0].Id).Broker_Firm__c,
            'Broker_Firm__c (custom, FLS-controlled) is selected under WITH SYSTEM_MODE');
    }

    /**
     * The null/empty-input contract matches `DispositionSelector.selectStagesByIds` per this
     * method's own ApexDoc — asserted here rather than assumed.
     */
    @isTest
    static void selectBrokerLabelsByIds_nullOrEmptyInput_returnsEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Contact> forNull = ContactSelector.selectBrokerLabelsByIds(null);
        List<Contact> forEmpty = ContactSelector.selectBrokerLabelsByIds(new Set<Id>());
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null Contact Id set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty Contact Id set short-circuits to an empty list, not null');
        Assert.areEqual(0, after - before, 'Neither call should spend a query — the empty-set guard runs before the SOQL');
    }

    /**
     * Bulk-safety at data volume, mirroring `DispositionSelector.selectStageAndTypeByIds_bulk251_
     * oneQueryForTheWholeSet` — the sibling SYSTEM_MODE automation-read proof on the caller's own
     * object. `DispositionBrokerStampService.stampSelectedBrokerLabel`'s own budget note requires
     * exactly ONE query for the whole trigger chunk; this is the selector-level half of that proof
     * (`DispositionBrokerStampServiceTest` proves the SERVICE issues exactly one call).
     */
    @isTest
    static void selectBrokerLabelsByIds_bulk251_oneQueryForTheWholeSet() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(BULK_N, null, false);
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.insert(brokers, dml);
        Set<Id> ids = new Map<Id, Contact>(brokers).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Contact> rows = ContactSelector.selectBrokerLabelsByIds(ids);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(), 'All 251 requested broker Contacts are returned');
        Assert.areEqual(1, queriesUsed, 'ONE query for the whole 251-row set, never one per record');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static User buildStandardUser() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'ctcstd' + String.valueOf(Datetime.now().getTime());
        return new User(
            FirstName = 'Std',
            LastName = 'ContactSel',
            Alias = 'ctcsel',
            Email = 'std.contactsel@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
