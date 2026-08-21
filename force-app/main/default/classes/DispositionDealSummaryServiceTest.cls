/**
 * @description Test class for DispositionDealSummaryService.
 *
 * ⚠ BULK VOLUME IS NOT 251 HERE, AND THAT IS DELIBERATE — READ BEFORE "FIXING" IT.
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate targets triggers, batch jobs and
 * DML-performing services that process a COLLECTION. `DispositionDealSummaryService.summarise` is
 * the opposite shape: it is a record-page read for exactly ONE Disposition, invoked once per page
 * load, and its own Javadoc already claims the per-transaction-singleton exemption in
 * `.claude/rules/bulk-test-rule.md` for exactly this reason — four fixed `LIMIT 1`-shaped selector
 * calls, regardless of data volume, with no loop to force a second batch. A 251-record bulk test
 * here would not exercise any additional code path in this service.
 *
 * What volume DOES matter for is the opposite question — does the CHILD count under one
 * Disposition change the query cost of reading it? `dispositionQueryCost_manyChildrenAcrossAllThreeObjects_stillFourQueries`
 * proves it does not, using 20 NDAs (not 251): `NDA_Signed_Rollup` is an AFTER-SAVE flow that
 * queries every sibling NDA on its OWN Disposition once per triggering NDA, so N NDA inserts under
 * one Disposition cost the SETUP transaction roughly N flow-driven queries before `Test.startTest()`
 * ever runs. 251 would risk tripping the 100-synchronous-SOQL ceiling on data setup alone, for a
 * fact (LIMIT 1 stays O(1)) that is exactly as provable at 20.
 *
 * ═══ THE FAIL-SOFT / DEGRADED-VS-EMPTY TESTS USE A DYNAMICALLY-BUILT PERMISSION SET, NOT A REAL
 *     DEPLOYED ONE ═══
 * Every real permission set in this org that grants `Disposition__c` also grants `NDA__c`, `LOI__c`
 * and `Contract_Review__c` (the same fact `BovControllerTest` records for why its own fail-soft
 * catch is an accepted, uncovered gap). So proving "one row degrades, the others don't" needs a
 * persona denied exactly one of the four objects at a time — a shape no assignable org persona has
 * today. `PermissionSet` / `ObjectPermissions` / `FieldPermissions` / `PermissionSetAssignment` are
 * ordinary sObjects that support Apex DML; `userDeniedAccessTo(String)` builds one per call, exact
 * and disposable, without touching any deployed metadata file. All are SETUP objects, so their DML
 * (together with the `User` insert) runs inside `System.runAs(new User(Id = UserInfo.getUserId()))`,
 * matching the MIXED_DML_OPERATION workaround
 * `RecordStageAdvanceServiceTest.transactionGateDeniesABareUserAndGrantsAPermissionSetHolder`
 * already uses — every caller of this helper ALSO inserts Disposition__c / NDA__c / LOI__c /
 * Contract_Review__c (non-setup) records in the same transaction, so the ordering trap applies here
 * too. `PermissionsViewAllRecords = true` is granted alongside `PermissionsRead` on every GRANTED
 * object so the restricted user can see rows an admin created without a sharing rule in the way —
 * `Disposition__c`, `NDA__c` and `LOI__c` are all OWD Private (measured in
 * `RecordStageAdvanceServiceTest`'s own header), and `NdaSelector`'s header names
 * `viewAllRecords = true` as the real mechanism this org already uses for exactly this problem.
 *
 * 🔴 MEASURED PLATFORM BEHAVIOUR: denying `Disposition__c` OBJECT access degrades ALL FOUR rows, not
 * just the one selector that reads `Disposition__c` directly. `WITH USER_MODE` on
 * `SELECT ... FROM NDA__c WHERE Disposition__c = :id` (and the identical shape on `LOI__c` /
 * `Contract_Review__c`) throws `No such column 'Disposition__c'` even when the CHILD object's own
 * `Disposition__c` lookup field carries an explicit `FieldPermissions` grant — reading a lookup field
 * that FILTERS on a target object also requires CRUD Read on that target object, not merely FLS on
 * the field. See `summarise_dispositionObjectDenied_allFourRowsDegrade`'s own header for the full
 * write-up; this narrows "one row degrades independently" for the Disposition__c-denial case
 * specifically, which the other three (deny NDA__c / LOI__c / Contract_Review__c individually) do
 * not share, because in those three cases `Disposition__c` itself stays granted.
 *
 * ⚠ `NDA_Count__c` / `Signed_NDA_Count__c` carry `<defaultValue>0</defaultValue>` in their field
 * metadata, so a freshly-inserted Disposition never organically reads null — see
 * `summarise_ndaCounts_nullOnPreexistingRowNotZero`'s own header for the measured detail and how the
 * null test constructs that state anyway. `summarise_ndaCounts_realSignedAndTotalPassThroughUnmodified`
 * separately does NOT rely on `NDA_Signed_Rollup` actually maintaining these counters — a diagnostic
 * run against `usman-dpeg` showed the flow does not currently update them after a real NDA save in
 * this org, which is a fact about that flow (production automation, not either class under test).
 *
 * @author Unit Testing Agent
 */
@isTest
private class DispositionDealSummaryServiceTest {

    @TestSetup
    static void setupTestData() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Disposition__c newDisposition() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        // On_Market default, Broker__c never touched — Broker_Lookup_Is_Off_Market_Only never engages.
        return TestDataFactory.createDisposition(asset.Id, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Null / missing input
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void summarise_nullDispositionId_returnsEmptySummary() {
        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(null);
        Test.stopTest();

        Assert.isNotNull(summary, 'A null Id must still return a (empty) summary, never null');
        Assert.isNull(summary.ndaCount, 'No counters on an empty summary');
        Assert.isFalse(summary.hasNda, 'No NDA row on an empty summary');
        Assert.isFalse(summary.hasLoi, 'No LOI row on an empty summary');
        Assert.isFalse(summary.hasPsa, 'No PSA row on an empty summary');
        Assert.isFalse(summary.ndaCountsUnavailable, 'A null Id is not a read failure');
        Assert.isFalse(summary.ndaUnavailable, 'A null Id is not a read failure');
        Assert.isFalse(summary.loiUnavailable, 'A null Id is not a read failure');
        Assert.isFalse(summary.psaUnavailable, 'A null Id is not a read failure');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fresh disposition, no children — empty state, distinct from "unavailable"
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void summarise_freshDispositionNoChildren_emptyNotUnavailable() {
        Disposition__c d = newDisposition();

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.isFalse(summary.hasNda, 'No NDA exists yet');
        Assert.isFalse(summary.hasLoi, 'No LOI exists yet');
        Assert.isFalse(summary.hasPsa, 'No PSA exists yet');
        Assert.isFalse(summary.ndaCountsUnavailable, 'The read itself succeeded, it just found nothing');
        Assert.isFalse(summary.ndaUnavailable, 'The read itself succeeded, it just found nothing');
        Assert.isFalse(summary.loiUnavailable, 'The read itself succeeded, it just found nothing');
        Assert.isFalse(summary.psaUnavailable, 'The read itself succeeded, it just found nothing');
    }

    /**
     * `Disposition__c.NDA_Count__c` / `Signed_NDA_Count__c` are maintained by the `NDA_Signed_Rollup`
     * AFTER-SAVE flow, and are supposed to be NULL — not zero — on any Disposition that has never
     * had an NDA save fire against it (per the field's own header: "Rows created before this field
     * existed hold null rather than 0"). 🔴 MEASURED, NOT ASSUMED: both fields carry
     * `<defaultValue>0</defaultValue>` in their field metadata, so — confirmed with a direct
     * diagnostic insert against `usman-dpeg` — EVERY freshly-inserted Disposition__c actually reads
     * 0 by platform default the instant it is created, never null; genuine null is reachable only by
     * a legacy row that predates the field, which cannot be constructed by inserting a new row at
     * all. The null path is proven here by explicitly assigning null before insert (which DOES
     * persist, unlike leaving the field untouched), which is the closest a test can get to that
     * legacy shape. This is worth recording because it means BLANKVALUE(...,0) on the client is
     * covering a state a fresh test fixture cannot organically produce.
     */
    @isTest
    static void summarise_ndaCounts_nullOnPreexistingRowNotZero() {
        Disposition__c d = newDisposition();
        d.NDA_Count__c = null;
        d.Signed_NDA_Count__c = null;
        update d;

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.isNull(summary.ndaCount, 'NDA_Count__c must read null, not 0, before the rollup flow ever fires');
        Assert.isNull(summary.ndaSignedCount, 'Signed_NDA_Count__c must read null, not 0, for the same reason');
        Assert.isFalse(summary.ndaCountsUnavailable, 'A null counter is a real value, not a read failure');
    }

    /**
     * 🔴 THIS DOES NOT RELY ON `NDA_Signed_Rollup` ACTUALLY FIRING CORRECTLY, AND THAT IS
     * DELIBERATE. A diagnostic run against `usman-dpeg` (outside this test, via anonymous Apex)
     * showed the flow does NOT currently update these counters after a real NDA save in this org —
     * `NDA_Count__c` / `Signed_NDA_Count__c` stayed at their 0 default after inserting NDAs directly.
     * That is a fact about the FLOW (production automation outside the two classes under test), not
     * about `DispositionDealSummaryService` or its selectors — see this class's header for the fuller
     * note. Stamping the counters directly with `update` isolates exactly what this test is meant to
     * prove: that the service/selector pass the RAW stored value through unmodified, regardless of
     * who or what wrote it.
     */
    @isTest
    static void summarise_ndaCounts_realSignedAndTotalPassThroughUnmodified() {
        Disposition__c d = newDisposition();
        d.NDA_Count__c = 2;
        d.Signed_NDA_Count__c = 1;
        update d;

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.areEqual(2, summary.ndaCount, 'The stored total must pass through unmodified');
        Assert.areEqual(1, summary.ndaSignedCount, 'The stored signed count must pass through unmodified');
        Assert.isFalse(summary.ndaCountsUnavailable, 'The read succeeded');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NDA tie-break — CreatedDate DESC, Id DESC
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 Two NDAs forced to an IDENTICAL CreatedDate in the same transaction. Without the `Id DESC`
     * tie-break, `ORDER BY CreatedDate DESC LIMIT 1` is free to return either row and the card
     * becomes non-deterministic between refreshes — exactly the failure `NdaSelector
     * .selectLatestSummaryByDispositionId`'s header exists to prevent. The expected winner is
     * established independently (query for the max-Id row), not assumed from list-insertion order.
     */
    @isTest
    static void summarise_ndaTieBreak_identicalCreatedDate_higherIdWins() {
        Disposition__c d = newDisposition();
        List<NDA__c> ndas = TestDataFactory.createDispositionNdas(2, d.Id, false);
        ndas[0].Status__c = 'Not Sent';
        ndas[1].Status__c = 'Signed';
        ndas[1].Date_Signed__c = Date.today();
        insert ndas;
        DateTime tiedMoment = System.now();
        Test.setCreatedDate(ndas[0].Id, tiedMoment);
        Test.setCreatedDate(ndas[1].Id, tiedMoment);

        NDA__c expectedWinner = [
            SELECT Id, Status__c, Date_Signed__c FROM NDA__c
            WHERE Disposition__c = :d.Id ORDER BY Id DESC LIMIT 1
        ];

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.areEqual(expectedWinner.Status__c, summary.ndaStatus,
            'The Id-DESC tie-break winner must be the one the card shows');
        Assert.areEqual(expectedWinner.Date_Signed__c, summary.ndaSignedDate,
            'Its Date_Signed__c must travel with it, not the other row\'s');
        Assert.isTrue(summary.hasNda, 'An NDA does exist');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOI tie-break, positive shape and the two deliberate field exclusions
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 `Ball_In_Court__c` USES `Us` / `Buyer` HERE, NOT `Us` / `Seller` — READ BEFORE "FIXING".
     * `Disposition_LOI.recordType-meta.xml` restricts this field's picklist to exactly `{Us, Buyer}`
     * on the disposition side ('Seller' would name DPEG a second time, the same inversion the
     * `Buyer` value exists to fix — see that file's own W2 correction). ⚠ THAT FILE ALSO CLAIMS
     * "record-type picklist restriction remains UI-ONLY and is NOT enforced by Apex DML" —
     * MEASURED FALSE against `usman-dpeg` while writing this test: a plain `insert` of `'Seller'`
     * on a `Disposition_LOI`-typed row throws `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`. This is a
     * real, reportable documentation defect in that record-type file (not in either class under
     * test) — see the Unit Testing Report for the write-up. Do not "correct" this test back to
     * 'Seller'; that value is genuinely invalid here.
     */
    @isTest
    static void summarise_loiTieBreak_identicalCreatedDate_higherIdWins() {
        Disposition__c d = newDisposition();
        List<LOI__c> lois = TestDataFactory.createDispositionLois(2, d.Id, false);
        lois[0].Stage__c = 'Received';
        lois[0].Offer_Price__c = 1000000;
        lois[0].Ball_In_Court__c = 'Us';
        lois[1].Stage__c = 'Under Review';
        lois[1].Offer_Price__c = 1250000;
        lois[1].Ball_In_Court__c = 'Buyer';
        insert lois;
        DateTime tiedMoment = System.now();
        Test.setCreatedDate(lois[0].Id, tiedMoment);
        Test.setCreatedDate(lois[1].Id, tiedMoment);

        LOI__c expectedWinner = [
            SELECT Id, Stage__c, Offer_Price__c, Ball_In_Court__c FROM LOI__c
            WHERE Disposition__c = :d.Id ORDER BY Id DESC LIMIT 1
        ];

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.areEqual(expectedWinner.Stage__c, summary.loiStage, 'The Id-DESC winner\'s stage must show');
        Assert.areEqual(expectedWinner.Offer_Price__c, summary.loiOfferPrice, 'And its offer price');
        Assert.areEqual(expectedWinner.Ball_In_Court__c, summary.loiBallInCourt, 'And its ball-in-court');
        Assert.isTrue(summary.hasLoi, 'An LOI does exist');
    }

    /**
     * `LOI_Status__c` and `LOI_Signed_Date__c` are deliberately absent from the DTO — see the
     * service header's C-10 / C-11 discussion. This proves both the positive shape (Stage__c,
     * Offer_Price__c, Ball_In_Court__c populate) and, by serializing the DTO, that no member named
     * for either excluded field exists on the wire at all.
     */
    @isTest
    static void summarise_loi_excludesStatusAndSignedDateFields() {
        Disposition__c d = newDisposition();
        LOI__c loi = TestDataFactory.createDispositionLoi(d.Id, false);
        loi.Stage__c = 'Executed';
        // Final_Agreed_Price__c is required by an active validation rule the instant Stage__c is
        // 'Executed' (unconditional, not ISCHANGED-guarded — it fires on insert too).
        loi.Final_Agreed_Price__c = 2000000;
        loi.Offer_Price__c = 2000000;
        loi.Ball_In_Court__c = 'Buyer'; // 'Seller' is invalid on Disposition_LOI — see the tie-break test's header
        insert loi;

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.areEqual('Executed', summary.loiStage, 'Stage__c is the real sell-side vocabulary');
        Assert.areEqual(2000000, summary.loiOfferPrice, 'Offer_Price__c must populate');
        Assert.areEqual('Buyer', summary.loiBallInCourt, 'Ball_In_Court__c must populate');

        String json = JSON.serialize(summary);
        Assert.isFalse(json.contains('loiSignedDate'),
            'LOI_Signed_Date__c is structurally always blank on a sale (Signed Status Sync keys on '
            + 'the ACQUISITION terminal) and must never be a DTO member: ' + json);
        Assert.isFalse(json.contains('loiStatus'),
            'LOI_Status__c is never set by any automation on a sale (would show its Draft default '
            + 'beside an Executed Stage) and must never be a DTO member: ' + json);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PSA tie-break and the source-field-not-projection contract
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void summarise_psaTieBreak_identicalCreatedDate_higherIdWins() {
        Disposition__c d = newDisposition();
        List<Contract_Review__c> reviews = TestDataFactory.createDispositionContractReviews(2, d.Id, false);
        reviews[0].Negotiation_Status__c = 'Initial Draft';
        reviews[1].Negotiation_Status__c = 'Revised';
        reviews[1].Execution_Date__c = null;
        insert reviews;
        DateTime tiedMoment = System.now();
        Test.setCreatedDate(reviews[0].Id, tiedMoment);
        Test.setCreatedDate(reviews[1].Id, tiedMoment);

        Contract_Review__c expectedWinner = [
            SELECT Id, Negotiation_Status__c FROM Contract_Review__c
            WHERE Disposition__c = :d.Id ORDER BY Id DESC LIMIT 1
        ];

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.areEqual(expectedWinner.Negotiation_Status__c, summary.psaStatus,
            'The Id-DESC winner\'s negotiation status must show');
        Assert.isTrue(summary.hasPsa, 'A PSA does exist');
    }

    /**
     * 🔴 `psaStatus` MUST carry `Negotiation_Status__c` (the SOURCE field), never `Stage__c` (a
     * derived projection that collapses 'Revised' and 'Ready for Execution' into one 'Review'
     * value). 'Revised' is asserted directly, and 'Review' — what the projection would show instead
     * — is asserted absent, so a future refactor that swaps the selected field breaks this loudly.
     */
    @isTest
    static void summarise_psa_readsSourceNegotiationStatusNotStageProjection() {
        Disposition__c d = newDisposition();
        Contract_Review__c cr = TestDataFactory.createDispositionContractReview(d.Id, false);
        cr.Negotiation_Status__c = 'Revised';
        insert cr;

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.areEqual('Revised', summary.psaStatus,
            'The source field value must pass through unmodified');
        Assert.areNotEqual('Review', summary.psaStatus,
            'The derived Stage__c projection value must never leak in here');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fail-soft: one row degrades, the other two do not — and degraded != empty
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Builds a Standard User with a dynamically-constructed PermissionSet that grants Read (+
     * ViewAllRecords, to cross the Private-OWD sharing gap for rows this admin-created data did not
     * assign the user ownership of) on every one of {Disposition__c, NDA__c, LOI__c,
     * Contract_Review__c} EXCEPT `deniedSobjectType` — no ObjectPermissions row, no FieldPermissions
     * row for that one object at all. `WITH USER_MODE` throws on a CRUD-level object denial (the
     * same behaviour BovControllerTest's header documents for a bare user against Disposition__c),
     * which is exactly what makes only the denied object's row degrade while the other three read
     * normally — proving each of the four independent try/catch blocks in isolation.
     *
     * Both User and PermissionSet-family DML are SETUP-object DML; both run inside
     * `System.runAs(new User(Id = UserInfo.getUserId()))` because every caller of this helper ALSO
     * performs non-setup DML (Disposition__c/NDA__c/LOI__c/Contract_Review__c) in the same
     * transaction — see this class's header.
     *
     * @param deniedSobjectType One of 'Disposition__c', 'NDA__c', 'LOI__c', 'Contract_Review__c'.
     */
    private static User userDeniedAccessTo(String deniedSobjectType) {
        Map<String, List<String>> fieldsByObject = new Map<String, List<String>>{
            'Disposition__c' => new List<String>{ 'NDA_Count__c', 'Signed_NDA_Count__c' },
            'NDA__c' => new List<String>{ 'Status__c', 'Date_Signed__c', 'Disposition__c' },
            'LOI__c' => new List<String>{ 'Stage__c', 'Offer_Price__c', 'Ball_In_Court__c', 'Disposition__c' },
            'Contract_Review__c' => new List<String>{
                'Negotiation_Status__c', 'Execution_Date__c', 'Latest_Version__c', 'Disposition__c' }
        };

        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'dsflstst' + String.valueOf(DateTime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User bare = new User(
            FirstName = 'Deal',
            LastName = 'SummaryFlsTest',
            Alias = 'dsfls',
            Email = 'dsflstst@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );

        PermissionSet ps = new PermissionSet(
            Name = 'Deal_Summary_Deny_' + String.valueOf(DateTime.now().getTime())
                + String.valueOf(Math.abs(Crypto.getRandomInteger())),
            Label = 'Deal Summary Test - Denied Access'
        );

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bare;
            insert ps;

            List<ObjectPermissions> objPerms = new List<ObjectPermissions>();
            List<FieldPermissions> fieldPerms = new List<FieldPermissions>();
            for (String sobjType : fieldsByObject.keySet()) {
                if (sobjType == deniedSobjectType) {
                    continue; // no ObjectPermissions, no FieldPermissions — zero access.
                }
                objPerms.add(new ObjectPermissions(ParentId = ps.Id, SobjectType = sobjType,
                    PermissionsRead = true, PermissionsViewAllRecords = true));
                for (String fieldName : fieldsByObject.get(sobjType)) {
                    fieldPerms.add(new FieldPermissions(ParentId = ps.Id, SobjectType = sobjType,
                        Field = sobjType + '.' + fieldName, PermissionsRead = true));
                }
            }
            insert objPerms;
            insert fieldPerms;
            insert new PermissionSetAssignment(AssigneeId = bare.Id, PermissionSetId = ps.Id);
        }
        return bare;
    }

    @isTest
    static void summarise_loiReadDenied_ndaAndPsaRowsStillPopulateWithRealValues() {
        Disposition__c d = newDisposition();
        NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
        nda.Status__c = 'Signed';
        nda.Date_Signed__c = Date.today();
        insert nda;
        // Stage__c stays at its seeded default ('Received') — this test proves the row is DENIED,
        // not its specific field values, so there is no need to cross the Final_Agreed_Price__c
        // validation rule that 'Executed' requires (see the tie-break test's header).
        LOI__c loi = TestDataFactory.createDispositionLoi(d.Id, true);
        Contract_Review__c cr = TestDataFactory.createDispositionContractReview(d.Id, false);
        cr.Negotiation_Status__c = 'Ready for Execution';
        insert cr;

        User restricted = userDeniedAccessTo('LOI__c');

        DispositionDealSummaryService.DealSummary summary;
        System.runAs(restricted) {
            Test.startTest();
            summary = DispositionDealSummaryService.summarise(d.Id);
            Test.stopTest();
        }

        // The one denied row degrades ...
        Assert.isTrue(summary.loiUnavailable,
            'LOI__c was granted no access at all for this persona, so the row must degrade');
        Assert.isFalse(summary.hasLoi, 'A degraded row must not also claim to have found data');

        // ... and the other two rows are UNAFFECTED, with REAL values, not blanked.
        Assert.isFalse(summary.ndaUnavailable, 'The NDA read was fully granted and must succeed');
        Assert.isTrue(summary.hasNda, 'The NDA read must find the real row');
        Assert.areEqual('Signed', summary.ndaStatus, 'The NDA row must carry its real status');
        Assert.isFalse(summary.ndaCountsUnavailable, 'The Disposition counter read was fully granted');

        Assert.isFalse(summary.psaUnavailable, 'The PSA read was fully granted and must succeed');
        Assert.isTrue(summary.hasPsa, 'The PSA read must find the real row');
        Assert.areEqual('Ready for Execution', summary.psaStatus, 'The PSA row must carry its real status');
    }

    /**
     * 🔴 A DENIAL DOMINATES AN ABSENCE: the same restricted persona, but with NO LOI ROW INSERTED AT
     * ALL, still degrades. `WITH USER_MODE` is refused before the query can discover there was
     * nothing to return, so `loiUnavailable = true` even though a fully-granted reader would have
     * seen an ordinary empty row. That is the correct and the SAFE direction — the flag means "this
     * card could not read LOI", never "an LOI exists that you cannot see" — and it is worth pinning
     * because the opposite behaviour (degrade only when rows actually exist) is what a reader
     * intuitively expects and is exactly the shape that hid a real provisioning gap for months on
     * the BOV pill (see the service header's C-1 note).
     *
     * ⚠ RENAMED AND RE-DOCUMENTED 2026-08-20 (code review W2). It was
     * `summarise_loiReadDenied_butNoLoiExists_stillReadsAsEmptyNotUnavailable`, and its ApexDoc
     * promised *"empty, `loiUnavailable = false`"* — the exact OPPOSITE of the `Assert.isTrue`
     * it has always carried. A test whose name and doc contradict its assertion CANNOT FAIL WHEN THE
     * BEHAVIOUR IT NAMES BREAKS, and is worse than no test: it reads, in a coverage report and in a
     * reviewer's scan, as proof of a property nothing checks. The assertion was right and the name
     * was wrong, so the name moved.
     *
     * ⚠ IT IS NOT THE EMPTY-VS-DEGRADED PROOF — THAT IS
     * `summarise_freshDispositionNoChildren_emptyNotUnavailable` (above), which reads as a
     * FULLY-GRANTED user and asserts `hasLoi = false` WITH `loiUnavailable = false`. This one is its
     * mirror: same `hasLoi = false`, opposite flag, and the CONTRAST between the two is what proves
     * the two states are distinguishable at all.
     */
    @isTest
    static void summarise_loiReadDenied_butNoLoiExists_isStillUnavailableNotEmpty() {
        Disposition__c d = newDisposition();
        NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
        nda.Status__c = 'Not Sent';
        insert nda;

        User restricted = userDeniedAccessTo('LOI__c');

        DispositionDealSummaryService.DealSummary summary;
        System.runAs(restricted) {
            Test.startTest();
            summary = DispositionDealSummaryService.summarise(d.Id);
            Test.stopTest();
        }

        // The denial is reported even though there was nothing to deny: the query is refused before
        // it can discover the row count, so this persona cannot distinguish "no LOI" from "no
        // access" — and the service correctly reports the one it knows. hasLoi=false is shared with
        // summarise_freshDispositionNoChildren_emptyNotUnavailable; the FLAG is the whole difference.
        Assert.isFalse(summary.hasLoi, 'No LOI exists on this disposition');
        Assert.isTrue(summary.loiUnavailable,
            'DENIAL DOMINATES ABSENCE: this persona cannot read LOI__c at all, so the row must '
            + 'degrade regardless of whether an LOI exists. A false here would mean a real '
            + 'permission gap was being reported to the user as an ordinary empty sale.');
    }

    /**
     * The NDA row's OWN catch is independent of the other three — denying NDA__c specifically must
     * degrade only `ndaUnavailable`/`hasNda`, leaving the Disposition-level counters (a DIFFERENT
     * object, DispositionSelector.selectNdaCountsById) and LOI/PSA untouched. This is the "one catch
     * per row" contract the service header calls out for the NDA row specifically ("four catches for
     * three rows").
     */
    @isTest
    static void summarise_ndaReadDenied_countsLoiAndPsaRowsStillPopulateWithRealValues() {
        Disposition__c d = newDisposition();
        NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
        nda.Status__c = 'Signed';
        insert nda; // real row exists on the object being denied — proves the DENIAL, not absence, causes the degrade
        LOI__c loi = TestDataFactory.createDispositionLoi(d.Id, false);
        loi.Stage__c = 'Under Review';
        insert loi;
        Contract_Review__c cr = TestDataFactory.createDispositionContractReview(d.Id, false);
        cr.Negotiation_Status__c = 'Revised';
        insert cr;

        User restricted = userDeniedAccessTo('NDA__c');

        DispositionDealSummaryService.DealSummary summary;
        System.runAs(restricted) {
            Test.startTest();
            summary = DispositionDealSummaryService.summarise(d.Id);
            Test.stopTest();
        }

        Assert.isTrue(summary.ndaUnavailable, 'NDA__c was granted no access, so this row must degrade');
        Assert.isFalse(summary.hasNda, 'A degraded row must not also claim to have found data');

        Assert.isFalse(summary.ndaCountsUnavailable,
            'The Disposition-level counter read is a DIFFERENT object/selector and must be unaffected');
        Assert.isFalse(summary.loiUnavailable, 'The LOI read was fully granted and must succeed');
        Assert.isTrue(summary.hasLoi, 'The LOI read must find the real row');
        Assert.areEqual('Under Review', summary.loiStage, 'The LOI row must carry its real stage');
        Assert.isFalse(summary.psaUnavailable, 'The PSA read was fully granted and must succeed');
        Assert.isTrue(summary.hasPsa, 'The PSA read must find the real row');
        Assert.areEqual('Revised', summary.psaStatus, 'The PSA row must carry its real status');
    }

    /** Symmetric proof on the PSA row: denying Contract_Review__c degrades only that row. */
    @isTest
    static void summarise_psaReadDenied_ndaAndLoiRowsStillPopulateWithRealValues() {
        Disposition__c d = newDisposition();
        NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
        nda.Status__c = 'Signed';
        insert nda;
        LOI__c loi = TestDataFactory.createDispositionLoi(d.Id, false);
        loi.Stage__c = 'Under Review';
        insert loi;
        Contract_Review__c cr = TestDataFactory.createDispositionContractReview(d.Id, false);
        cr.Negotiation_Status__c = 'Revised';
        insert cr;

        User restricted = userDeniedAccessTo('Contract_Review__c');

        DispositionDealSummaryService.DealSummary summary;
        System.runAs(restricted) {
            Test.startTest();
            summary = DispositionDealSummaryService.summarise(d.Id);
            Test.stopTest();
        }

        Assert.isTrue(summary.psaUnavailable, 'Contract_Review__c was granted no access, so this row must degrade');
        Assert.isFalse(summary.hasPsa, 'A degraded row must not also claim to have found data');

        Assert.isFalse(summary.ndaUnavailable, 'The NDA read was fully granted and must succeed');
        Assert.isTrue(summary.hasNda, 'The NDA read must find the real row');
        Assert.isFalse(summary.loiUnavailable, 'The LOI read was fully granted and must succeed');
        Assert.isTrue(summary.hasLoi, 'The LOI read must find the real row');
        Assert.areEqual('Under Review', summary.loiStage, 'The LOI row must carry its real stage');
    }

    /**
     * 🔴 MEASURED FINDING, NOT THE ORIGINAL HYPOTHESIS — denying `Disposition__c` object access
     * degrades ALL FOUR reads, not just `applyNdaCounts`'s own. This test originally asserted the
     * child rows (NDA__c/LOI__c/Contract_Review__c) would be unaffected, on the theory that filtering
     * `WHERE Disposition__c = :id` only needs FLS on the child object's OWN lookup field. A direct
     * diagnostic against `usman-dpeg` disproved that: `WITH USER_MODE` on
     * `SELECT ... FROM NDA__c WHERE Disposition__c = :id` throws `System.QueryException: No such
     * column 'Disposition__c' on entity 'NDA__c'` even when `NDA__c.Disposition__c` itself carries an
     * explicit `FieldPermissions(PermissionsRead = true)` grant — the platform additionally requires
     * at least CRUD Read on the REFERENCED object (`Disposition__c`) for a lookup field pointing at
     * it to be queryable at all. This applies symmetrically to `LoiSelector` and
     * `ContractReviewSelector`'s equivalent `Disposition__c`-filtered reads, so denying the parent
     * object is a WHOLE-CARD-DEGRADING event by construction — a real, narrower boundary on the
     * "one row degrades independently" design than the header describes for the other three cases,
     * worth recording rather than silently working around.
     */
    @isTest
    static void summarise_dispositionObjectDenied_allFourRowsDegrade() {
        Disposition__c d = newDisposition();
        NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
        nda.Status__c = 'Signed';
        insert nda;
        LOI__c loi = TestDataFactory.createDispositionLoi(d.Id, false);
        loi.Stage__c = 'Under Review';
        insert loi;
        Contract_Review__c cr = TestDataFactory.createDispositionContractReview(d.Id, false);
        cr.Negotiation_Status__c = 'Revised';
        insert cr;

        User restricted = userDeniedAccessTo('Disposition__c');

        DispositionDealSummaryService.DealSummary summary;
        System.runAs(restricted) {
            Test.startTest();
            summary = DispositionDealSummaryService.summarise(d.Id);
            Test.stopTest();
        }

        Assert.isTrue(summary.ndaCountsUnavailable, 'Disposition__c was granted no access, so the counter read must degrade');
        Assert.isNull(summary.ndaCount, 'A degraded counter read must not report an invented value');
        Assert.isTrue(summary.ndaUnavailable,
            'The NDA__c WHERE Disposition__c=:id filter needs Read on the referenced object too — it must degrade');
        Assert.isFalse(summary.hasNda, 'A degraded row must not also claim to have found data');
        Assert.isTrue(summary.loiUnavailable, 'Same platform behaviour applies to the LOI read');
        Assert.isFalse(summary.hasLoi, 'A degraded row must not also claim to have found data');
        Assert.isTrue(summary.psaUnavailable, 'Same platform behaviour applies to the PSA read');
        Assert.isFalse(summary.hasPsa, 'A degraded row must not also claim to have found data');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Row Ids — the card's click-through targets (added 2026-08-21 with the restyle)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * `ndaId` / `loiId` / `psaId` back the row-label links on `c/dispositionDealSummary` after the
     * 2026-08-21 restyle. Two things are proven at once, and the second is the interesting one:
     *
     *   1. Each Id is populated when the child exists.
     *   2. 🔴 EACH ID IS THE SAME ROW THE REST OF THAT ROW'S DATA CAME FROM. A link pointing at a
     *      DIFFERENT record from the status beside it would be worse than no link — the reader
     *      would open a record that does not say what the card just said. Two children per object
     *      are inserted and forced to an IDENTICAL CreatedDate, so the Id-DESC tie-break decides
     *      the winner, and the expected winner is established independently by querying for the
     *      max Id rather than assumed from list-insertion order. The status assertions are
     *      alongside the Id assertions on purpose: they must agree.
     *
     * ⚠ No new SOQL was added to any selector for this. `Id` is returned by every SOQL query
     * whether or not it is named in the SELECT list, and it has no `FieldPermissions` row on any
     * permission set, so there is no new `WITH USER_MODE` FLS gate to trip.
     */
    @isTest
    static void summarise_rowIds_matchTheSameRecordEachRowsDataCameFrom() {
        Disposition__c d = newDisposition();

        List<NDA__c> ndas = TestDataFactory.createDispositionNdas(2, d.Id, false);
        ndas[0].Status__c = 'Not Sent';
        ndas[1].Status__c = 'Signed';
        insert ndas;
        List<LOI__c> lois = TestDataFactory.createDispositionLois(2, d.Id, false);
        lois[0].Stage__c = 'Received';
        lois[1].Stage__c = 'Under Review';
        insert lois;
        List<Contract_Review__c> reviews = TestDataFactory.createDispositionContractReviews(2, d.Id, false);
        reviews[0].Negotiation_Status__c = 'Initial Draft';
        reviews[1].Negotiation_Status__c = 'Revised';
        insert reviews;

        DateTime tiedMoment = System.now();
        for (NDA__c n : ndas) {
            Test.setCreatedDate(n.Id, tiedMoment);
        }
        for (LOI__c l : lois) {
            Test.setCreatedDate(l.Id, tiedMoment);
        }
        for (Contract_Review__c r : reviews) {
            Test.setCreatedDate(r.Id, tiedMoment);
        }

        NDA__c expectedNda = [
            SELECT Id, Status__c FROM NDA__c WHERE Disposition__c = :d.Id ORDER BY Id DESC LIMIT 1
        ];
        LOI__c expectedLoi = [
            SELECT Id, Stage__c FROM LOI__c WHERE Disposition__c = :d.Id ORDER BY Id DESC LIMIT 1
        ];
        Contract_Review__c expectedPsa = [
            SELECT Id, Negotiation_Status__c FROM Contract_Review__c
            WHERE Disposition__c = :d.Id ORDER BY Id DESC LIMIT 1
        ];

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(expectedNda.Id), summary.ndaId,
            'ndaId must be the Id-DESC tie-break winner — the same NDA whose status the card shows');
        Assert.areEqual(expectedNda.Status__c, summary.ndaStatus,
            'and its status must be the one that travelled with it');
        Assert.areEqual(String.valueOf(expectedLoi.Id), summary.loiId,
            'loiId must be the Id-DESC tie-break winner');
        Assert.areEqual(expectedLoi.Stage__c, summary.loiStage,
            'and its stage must be the one that travelled with it');
        Assert.areEqual(String.valueOf(expectedPsa.Id), summary.psaId,
            'psaId must be the Id-DESC tie-break winner');
        Assert.areEqual(expectedPsa.Negotiation_Status__c, summary.psaStatus,
            'and its negotiation status must be the one that travelled with it');
    }

    /** No child, no Id — the client renders a muted, unlinked label rather than a dead link. */
    @isTest
    static void summarise_rowIds_nullOnAFreshDispositionWithNoChildren() {
        Disposition__c d = newDisposition();

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Test.stopTest();

        Assert.isNull(summary.ndaId, 'There is no NDA to link to');
        Assert.isNull(summary.loiId, 'There is no LOI to link to');
        Assert.isNull(summary.psaId, 'There is no PSA to link to');
    }

    /**
     * 🔴 A DEGRADED ROW MUST NOT LEAK AN ID. The card turns a non-null Id into a clickable link,
     * so an Id surviving a REFUSED read would offer the reader a link to a record they were just
     * denied — a link that can only end in a second permission error, presented as though the
     * card had successfully read the record. The guarantee is structural rather than conditional:
     * `applyLatestLoi` assigns `summary.loiId` INSIDE its try, after the selector returns, so a
     * throw leaves it at its null default. This test is what fails if that assignment is ever
     * hoisted out of the try or defaulted to something non-null.
     *
     * ⚠ A REAL LOI IS INSERTED FIRST, so what is proven is that the DENIAL suppresses the Id, not
     * merely that there was no record to take one from.
     */
    @isTest
    static void summarise_loiReadDenied_loiIdIsNullSoNoLinkCanBeOffered() {
        Disposition__c d = newDisposition();
        NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
        nda.Status__c = 'Signed';
        insert nda;
        // Stage__c stays at its seeded default — this test is about the Id, not the stage.
        LOI__c loi = TestDataFactory.createDispositionLoi(d.Id, true);
        Assert.isNotNull(loi.Id, 'A real LOI exists — the denial, not an absence, must null the Id');

        User restricted = userDeniedAccessTo('LOI__c');

        DispositionDealSummaryService.DealSummary summary;
        System.runAs(restricted) {
            Test.startTest();
            summary = DispositionDealSummaryService.summarise(d.Id);
            Test.stopTest();
        }

        Assert.isTrue(summary.loiUnavailable, 'The LOI read was refused for this persona');
        Assert.isNull(summary.loiId,
            'A DEGRADED row must carry no Id: the card would render it as a link to a record this '
            + 'reader was just refused, which can only end in a second permission error dressed up '
            + 'as a successful read.');

        // The granted rows keep theirs — the Id suppression is per row, like every other flag here.
        Assert.isFalse(summary.ndaUnavailable, 'The NDA read was fully granted');
        Assert.areEqual(String.valueOf(nda.Id), summary.ndaId,
            'The NDA row keeps its Id and therefore its link');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Disposition not found — the read-for-display null contract, not an error
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * A syntactically valid Id that no longer resolves to any row (deleted after being captured).
     * `DispositionSelector.selectNdaCountsById` returns null on the miss, and `applyNdaCounts`'s
     * `if (disposition == null) { return; }` branch is the only way to reach that path — a null
     * `dispositionId` short-circuits inside `summarise` itself before ever calling it.
     */
    @isTest
    static void summarise_dispositionIdNoLongerResolves_returnsEmptySummaryNotError() {
        Disposition__c d = newDisposition();
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(deletedId);
        Test.stopTest();

        Assert.isNull(summary.ndaCount, 'A vanished Disposition reads as empty, not as an invented value');
        Assert.isFalse(summary.ndaCountsUnavailable, 'A miss is a normal read-for-display state, not a failure');
        Assert.isFalse(summary.hasNda, 'No child rows can resolve against a vanished parent Id');
        Assert.isFalse(summary.hasLoi, 'No child rows can resolve against a vanished parent Id');
        Assert.isFalse(summary.hasPsa, 'No child rows can resolve against a vanished parent Id');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Query-cost proof: LIMIT-1 selectors stay O(1) as child volume grows
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 20 NDAs, 5 LOIs and 5 Contract Reviews under ONE Disposition (well short of the
     * `NDA_Signed_Rollup` flow's per-insert query cost tripping the 100-synchronous-SOQL ceiling
     * during setup — see this class's header for why 251 is the wrong number to reach for here).
     * `summarise` must still cost exactly the same small, fixed number of queries as the
     * zero-children case: one `LIMIT 1` read per row, never a query that scales with sibling count.
     */
    @isTest
    static void dispositionQueryCost_manyChildrenAcrossAllThreeObjects_stillFourQueries() {
        Disposition__c d = newDisposition();
        List<NDA__c> ndas = TestDataFactory.createDispositionNdas(20, d.Id, false);
        for (Integer i = 0; i < ndas.size(); i++) {
            ndas[i].Status__c = 'Not Sent';
        }
        insert ndas;
        TestDataFactory.createDispositionLois(5, d.Id, true);
        TestDataFactory.createDispositionContractReviews(5, d.Id, true);

        Test.startTest();
        DispositionDealSummaryService.DealSummary summary = DispositionDealSummaryService.summarise(d.Id);
        Integer queriesUsed = Limits.getQueries();
        Test.stopTest();

        Assert.isNotNull(summary, 'The read must still succeed at this volume');
        Assert.isTrue(queriesUsed <= 4,
            'summarise() issues exactly one LIMIT-1 query per row (4 total); it must not scale with '
            + 'sibling count. Queries used: ' + queriesUsed);
    }
}
