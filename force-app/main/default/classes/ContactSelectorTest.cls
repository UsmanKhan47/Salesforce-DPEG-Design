/**
 * Tests for ContactSelector (P4, Module B2 — Property Management; standard object).
 *
 * Covers the single relocated query:
 *   - selectBrokersOrderedByName : the Is_Broker__c = true filter, ORDER BY Name,
 *     Broker_Firm__c population, the no-brokers empty result, AND the standard-object
 *     USER_MODE proof required by design §7.
 *
 * USER_MODE PROOF NUANCE (design mismatch flagged to the orchestrator): unlike the
 * Task standard-object proof, this query selects the CUSTOM Contact.Broker_Firm__c
 * and filters the CUSTOM Contact.Is_Broker__c. A bare Standard User has no FLS on
 * those custom fields, so USER_MODE would throw. The DPEG_Acquisitions permission
 * set is the ONLY permset granting them, so the runAs proof assigns it — mirroring
 * the real broker-options persona, and confirming USER_MODE returns rows once the
 * grants are present.
 *
 * @see force-app/main/default/classes/TaskSelectorTest.cls (P4 standard-object template)
 * @see agent-output/p4-selector-design.md (§3 #19, §5, §7)
 */
@isTest
private class ContactSelectorTest {

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
        // A non-broker Contact must be excluded (Is_Broker__c defaults false).
        TestDataFactory.createContact(null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersOrderedByName();
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Only Is_Broker__c = true Contacts are returned; the plain Contact is excluded');
        Assert.areEqual('Test Alpha', rows[0].Name, 'ORDER BY Name returns the alphabetically-first broker first');
        Assert.areEqual('Alpha Realty', rows[0].Broker_Firm__c, 'Broker_Firm__c is selected for the option label');
        Assert.areEqual('Test Zeta', rows[1].Name, 'The second broker sorts after the first by Name');
    }

    @isTest
    static void selectBrokersOrderedByName_noBrokers_returnsEmpty() {
        // Only non-broker Contacts exist.
        TestDataFactory.createContacts(3, null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersOrderedByName();
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'With no broker Contacts the selector returns an empty list, not null');
    }

    /**
     * Standard-object USER_MODE proof (design §5/§7). A freshly created Standard
     * User granted the DPEG_Acquisitions permission set (which grants FLS on the
     * custom Contact.Is_Broker__c / Broker_Firm__c this query touches) reads broker
     * rows under WITH USER_MODE. The broker Contacts are inserted INSIDE runAs so the
     * Standard User owns them (removing sharing as a variable and isolating the FLS
     * question). The User + PermissionSetAssignment DML is isolated in its own runAs
     * block to avoid MIXED_DML_OPERATION with the non-setup Contact DML.
     */
    @isTest
    static void selectBrokersOrderedByName_standardUserWithGrants_userModeReturnsRows() {
        User standardUser = buildStandardUser();
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DPEG_Acquisitions' LIMIT 1].Id;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert standardUser;
            insert new PermissionSetAssignment(AssigneeId = standardUser.Id, PermissionSetId = permSetId);
        }

        Test.startTest();
        System.runAs(standardUser) {
            // Insert 2 broker Contacts as the Standard User (side effect is the point;
            // the selector re-queries them), exercising create + FLS end-to-end.
            TestDataFactory.createBrokerContacts(2, null, true);

            List<Contact> rows = ContactSelector.selectBrokersOrderedByName();

            Assert.areEqual(2, rows.size(),
                'A Standard User granted DPEG_Acquisitions reads broker Contacts under WITH USER_MODE');
            Assert.isNotNull(rows[0].Broker_Firm__c,
                'Broker_Firm__c (custom, FLS-controlled) is readable under USER_MODE once DPEG_Acquisitions grants it');
        }
        Test.stopTest();
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
