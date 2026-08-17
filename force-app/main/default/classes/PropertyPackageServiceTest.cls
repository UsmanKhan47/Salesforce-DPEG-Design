/**
 * Test class for `PropertyPackageService` — the only writer of `Property_Package__c`.
 *
 * Scope: the two public methods, in isolation. The PIPELINE decisions that decide WHEN a package is
 * created (Decision E's `workList.size() > 1` gate, Decision C1's pre-loop placement, and the
 * governor budgets those imply) belong to `ExtractAddressQueueable` and are asserted in
 * `ExtractAddressQueueableTest`'s PROPERTY PACKAGE section — deliberately not duplicated here.
 *
 * ═══ ⚠ NO 251-RECORD BULK TEST, AND THE REASON IS STRUCTURAL RATHER THAN CONVENIENT ═══
 * `.claude/rules/bulk-test-rule.md` mandates 251 for "a service method with DML", and this class is
 * a documented exception on the same grounds `ExtractAddressQueueableTest` records for the routing
 * job. THREE independent facts, each sufficient on its own:
 *   1. `createForEmail` is SINGLE-RECORD BY CONSTRUCTION — ONE package per inbound email, called
 *      exactly once per `ExtractAddressQueueable` execution, and each email gets its own async
 *      transaction. There is no collection parameter to bulkify and no loop to force a second
 *      trigger chunk.
 *   2. 251 CALLS ARE ARITHMETICALLY IMPOSSIBLE: each is one DML statement, so the loop would die on
 *      `System.LimitException: Too many DML statements: 151` at call 151 — before proving anything
 *      about the code under test. Testing a volume that cannot execute is the exact anti-pattern the
 *      exemption exists to prevent.
 *   3. A PACKAGE CANNOT HAVE 251 MEMBERS EITHER. `ExtractAddressQueueable.MAX_PROPERTIES` is 10, so
 *      one email routes at most 10 properties -> at most 10 Leads, and after conversion at most 10
 *      Opportunities and 10 Properties. 251 members is a state production cannot produce.
 * WHAT IS COVERED INSTEAD — the genuine risks: the field mapping (each value on its intended field,
 * so a transposition shows up as a WRONG value rather than a coincidentally-equal one), every clip
 * and sanitize boundary that could otherwise throw and take a broker's claim with it, the required
 * `Name` fallback, the null-safe no-ops, and `stampRoutedOutcomes`' fail-soft contract.
 *
 * ⚠ SYSTEM_MODE IS NOT ASSERTABLE HERE, and pretending otherwise would be a vacuous test. Tests run
 * as an administrator in system mode by default, so a bare `insert` and a SYSTEM_MODE insert behave
 * identically in this context: the day-one `System.TypeException` these calls exist to prevent
 * happens because Metadata-API-deployed fields carry no FLS for ANY profile, which `@isTest` does
 * not reproduce. Every test below would pass with the AccessLevel argument deleted. The protection
 * is argued at the declaration in `PropertyPackageService`, and the falsifier is a real deploy.
 */
@isTest
private class PropertyPackageServiceTest {

    private static final String STAGING_SUBJECT = 'FW: Three-property portfolio, Dallas';

    private static Inbound_Email_Staging__c insertStaging() {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane.broker@example.invalid',
            Subject__c = STAGING_SUBJECT,
            Raw_Body__c = 'Three assets attached.',
            Status__c = 'Pending'
        );
        insert staging;
        return staging;
    }

    // ── createForEmail: the happy path and the field mapping ─────────────────

    @isTest
    static void createForEmail_mapsEveryValueOntoItsIntendedField() {
        Inbound_Email_Staging__c staging = insertStaging();
        Datetime receivedOn = Datetime.newInstanceGmt(2026, 8, 14, 9, 30, 0);

        Test.startTest();
        Id packageId = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 3, 'jane.broker@example.invalid', 'Jane Broker',
            staging.Id, receivedOn);
        Test.stopTest();

        Assert.isNotNull(packageId, 'A successful create must return the new Id, never null');
        Property_Package__c pkg = [
            SELECT Name, Property_Count__c, Broker_Email__c, Broker_Name__c,
                   Source_Staging_Id__c, Received_DateTime__c, Routed_Outcomes__c
            FROM Property_Package__c WHERE Id = :packageId
        ];
        // Every value is DISTINCT and recognisable, so a transposed argument shows up as the WRONG
        // value rather than as a coincidentally-equal one — the reason the six parameters are
        // asserted individually instead of by a spot check.
        Assert.areEqual(STAGING_SUBJECT, pkg.Name, 'Name is the email subject');
        Assert.areEqual(3, pkg.Property_Count__c, 'Property_Count__c is what the email named');
        Assert.areEqual('jane.broker@example.invalid', pkg.Broker_Email__c, 'Broker_Email__c');
        Assert.areEqual('Jane Broker', pkg.Broker_Name__c, 'Broker_Name__c');
        Assert.areEqual(String.valueOf(staging.Id), pkg.Source_Staging_Id__c,
            'Source_Staging_Id__c is a TEXT pointer to the staging row (Result_Record_Id__c\'s '
            + 'precedent), which is what makes the raw email recoverable from the package');
        Assert.areEqual(receivedOn, pkg.Received_DateTime__c, 'Received_DateTime__c');
        Assert.isNull(pkg.Routed_Outcomes__c,
            'Routed_Outcomes__c is DELIBERATELY not set at create time — the routing audit does not '
            + 'exist yet at this point in the transaction (Decision C1 puts creation BEFORE the '
            + 'per-property loop). stampRoutedOutcomes fills it afterwards');
    }

    @isTest
    static void createForEmail_costsExactlyOneDmlAndZeroSoql() {
        // 🔴 ZERO SOQL IS THE LOAD-BEARING HALF. The caller is `ExtractAddressQueueable`, whose
        // 10-property query budget (120, ceiling) and DML budget (45, EQUALITY) both assume this is
        // a BLIND insert. A "helpful" read here — checking for an existing package by staging Id,
        // say — would consume from a budget measured in the async transaction that owns the claim.
        Inbound_Email_Staging__c staging = insertStaging();

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 2, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        Integer queryDelta = Limits.getQueries() - q0;
        Integer dmlDelta = Limits.getDmlStatements() - d0;
        Test.stopTest();

        Assert.areEqual(0, queryDelta, 'createForEmail is a BLIND insert: zero SOQL, always');
        Assert.areEqual(1, dmlDelta, 'and exactly ONE DML statement');
    }

    @isTest
    static void createForEmail_nullReceivedOnIsStoredAsNullNotAsNow() {
        // The LLM frequently cannot parse a send time. A silent `now()` default here would fabricate
        // a fact — the behaviour this module forbids everywhere else — and Received_DateTime__c is
        // the only place a human could later notice it was never known.
        Inbound_Email_Staging__c staging = insertStaging();

        Test.startTest();
        Id packageId = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 2, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        Test.stopTest();

        Assert.isNull(
            [SELECT Received_DateTime__c FROM Property_Package__c WHERE Id = :packageId]
                .Received_DateTime__c,
            'An unknown send time must stay unknown, not become "now"');
    }

    // ── createForEmail: the boundaries that would otherwise ABORT ROUTING ────
    //
    // Every test below is about the same thing: this insert runs inside the transaction that owns
    // the Lead and the registry claim, so a value that THROWS costs a broker their first-come
    // protection. Each input is therefore clipped, sanitized or defaulted rather than trusted.

    @isTest
    static void createForEmail_overLongSubjectIsClippedNotRejected() {
        Inbound_Email_Staging__c staging = insertStaging();
        String longSubject = 'X'.repeat(200);   // Name is Text(80)

        Test.startTest();
        Id packageId = PropertyPackageService.createForEmail(
            longSubject, 2, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        Test.stopTest();

        Assert.areEqual(80,
            [SELECT Name FROM Property_Package__c WHERE Id = :packageId].Name.length(),
            'A 200-character subject must be CLIPPED to Name\'s 80. STRING_TOO_LONG here would roll '
            + 'back a committed registry claim for a broker whose only sin was a verbose subject line');
    }

    @isTest
    static void createForEmail_blankSubjectFallsBackBecauseNameIsRequired() {
        Inbound_Email_Staging__c staging = insertStaging();

        Test.startTest();
        Id fromBlank = PropertyPackageService.createForEmail(
            '   ', 2, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        Id fromNull = PropertyPackageService.createForEmail(
            null, 2, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        Test.stopTest();

        Assert.areEqual('Multi-Property Email',
            [SELECT Name FROM Property_Package__c WHERE Id = :fromBlank].Name,
            'Name is REQUIRED by the platform, so a blank subject must fall back — otherwise '
            + 'REQUIRED_FIELD_MISSING aborts the routing transaction. Brokers do send subject-less '
            + 'forwards');
        Assert.areEqual('Multi-Property Email',
            [SELECT Name FROM Property_Package__c WHERE Id = :fromNull].Name,
            'and a null subject takes the same path');
    }

    @isTest
    static void createForEmail_malformedBrokerEmailIsBlankedNotThrown() {
        // The LLM can return a display name, a truncated address, or a whole "From:" line.
        // Broker_Email__c is an Email field: a raw value would throw INVALID_EMAIL_ADDRESS.
        Inbound_Email_Staging__c staging = insertStaging();

        Test.startTest();
        Id packageId = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 2, 'Jane Broker <not an address>', 'Jane Broker', staging.Id, null);
        Test.stopTest();

        Assert.isNull(
            [SELECT Broker_Email__c FROM Property_Package__c WHERE Id = :packageId].Broker_Email__c,
            'A malformed address becomes BLANK — a field a human can fix — rather than an '
            + 'INVALID_EMAIL_ADDRESS that costs the email its claim');
    }

    @isTest
    static void createForEmail_overLongBrokerNameIsClipped() {
        Inbound_Email_Staging__c staging = insertStaging();
        String longName = 'N'.repeat(400);   // Broker_Name__c is Text(255)

        Test.startTest();
        Id packageId = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 2, 'jane.broker@example.invalid', longName, staging.Id, null);
        Test.stopTest();

        Assert.areEqual(255,
            [SELECT Broker_Name__c FROM Property_Package__c WHERE Id = :packageId]
                .Broker_Name__c.length(),
            'Clipped to 255. An LLM-extracted signature block can be arbitrarily long');
    }

    @isTest
    static void createForEmail_propertyCountIsClampedToWhatNumberTwoZeroCanHold() {
        // Property_Count__c is Number(2,0), so 100 would throw at DML. Unreachable today
        // (MAX_PROPERTIES is 10) is not the same as impossible, and the failure mode — a lost
        // broker submission — is wildly disproportionate to the cause.
        Inbound_Email_Staging__c staging = insertStaging();

        Test.startTest();
        Id clamped = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 500, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        Id nulled = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 0, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        Test.stopTest();

        Assert.areEqual(99,
            [SELECT Property_Count__c FROM Property_Package__c WHERE Id = :clamped].Property_Count__c,
            'Clamped to 99 — the largest value Number(2,0) stores — instead of throwing');
        Assert.isNull(
            [SELECT Property_Count__c FROM Property_Package__c WHERE Id = :nulled].Property_Count__c,
            'A zero or negative count is stored as null: "we do not know" rather than a false zero');
    }

    @isTest
    static void createForEmail_nullStagingIdLeavesThePointerBlank() {
        Test.startTest();
        Id packageId = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 2, 'jane.broker@example.invalid', 'Jane Broker', null, null);
        Test.stopTest();

        Assert.isNull(
            [SELECT Source_Staging_Id__c FROM Property_Package__c WHERE Id = :packageId]
                .Source_Staging_Id__c,
            'A null staging Id must not become the literal string "null" — the field is a pointer '
            + 'and a bogus one is worse than an empty one');
    }

    // ── stampRoutedOutcomes ─────────────────────────────────────────────────

    @isTest
    static void stampRoutedOutcomes_writesTheAuditOnAnExistingPackage() {
        Inbound_Email_Staging__c staging = insertStaging();
        Id packageId = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 2, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        String audit = '1001 multi st | New Lead (winner) | 00Q000000000001\n'
            + '1002 multi st | Competing Submission | 00Q000000000002';

        Test.startTest();
        PropertyPackageService.stampRoutedOutcomes(packageId, audit);
        Test.stopTest();

        Assert.areEqual(audit,
            [SELECT Routed_Outcomes__c FROM Property_Package__c WHERE Id = :packageId]
                .Routed_Outcomes__c,
            'Decision B2: the package carries the FULL audit verbatim, including the line for the '
            + 'property that went to another broker — which is the only reason this second '
            + 'statement is worth its cost');
    }

    @isTest
    static void stampRoutedOutcomes_nullInputsAreFreeNoOps() {
        // 🔴 THIS IS A GOVERNOR ASSERTION DISGUISED AS A NULL-SAFETY ONE. `finish()` calls this
        // unconditionally, on EVERY inbound email — including the single-property and gated paths
        // that have no package at all. If a null packageId cost one DML, every email in the pipeline
        // would pay for a feature it does not use, and the single-property `== 7` DML equality in
        // ExtractAddressQueueableTest would break.
        Inbound_Email_Staging__c staging = insertStaging();
        Id packageId = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 2, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);

        Test.startTest();
        Integer d0 = Limits.getDmlStatements();
        PropertyPackageService.stampRoutedOutcomes(null, 'ignored because there is no package');
        PropertyPackageService.stampRoutedOutcomes(packageId, null);
        PropertyPackageService.stampRoutedOutcomes(packageId, '   ');
        Integer dmlDelta = Limits.getDmlStatements() - d0;
        Test.stopTest();

        Assert.areEqual(0, dmlDelta,
            'All three no-op shapes must cost ZERO DML. finish() calls this on every email, so a '
            + 'null-packageId cost here is a cost on the whole pipeline');
        Assert.isNull(
            [SELECT Routed_Outcomes__c FROM Property_Package__c WHERE Id = :packageId]
                .Routed_Outcomes__c,
            'and a blank audit must not blank an existing value either');
    }

    @isTest
    static void stampRoutedOutcomes_failureIsSwallowedBecauseTheCanonicalCopyIsElsewhere() {
        // FAIL-SOFT, and the asymmetry with createForEmail (which THROWS) is the design. By the time
        // this runs the package exists, every Lead is linked to it, and the same text is already
        // permanent on the staging row's Routed_Record_Ids__c — so this writes a CONVENIENCE COPY.
        // Raising here would risk a correctly-routed email for a duplicate of recoverable data.
        //
        // A DELETED Id is the falsifier: it is a well-formed Property_Package__c Id whose row no
        // longer exists, so the update genuinely fails inside the service. The same technique the
        // repo uses elsewhere to reach a write/rollback catch.
        Inbound_Email_Staging__c staging = insertStaging();
        Id packageId = PropertyPackageService.createForEmail(
            STAGING_SUBJECT, 2, 'jane.broker@example.invalid', 'Jane Broker', staging.Id, null);
        delete [SELECT Id FROM Property_Package__c WHERE Id = :packageId];

        Test.startTest();
        PropertyPackageService.stampRoutedOutcomes(packageId, 'an audit with nowhere to land');
        Test.stopTest();

        // Reaching this line at all IS the assertion: an escaping DmlException would fail the test.
        Assert.areEqual(0, [SELECT COUNT() FROM Property_Package__c WHERE Id = :packageId],
            'Precondition: the row really is gone, so the update really did fail — otherwise this '
            + 'test proves nothing about the catch');
    }
}
