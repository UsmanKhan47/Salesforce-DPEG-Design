/**
 * Tests for PsaVersionSelector. Covers selectByContractReviewId (found ordered /
 * 251-bulk / null-input) and countByContractReviewId (count / null-input / the
 * 2026-08-09 access-mode change).
 * Factory-based per ARCHITECTURE.md §2; 251-record bulk per
 * .claude/rules/bulk-test-rule.md.
 *
 * ── 🔴 THE TWO METHODS RUN IN DIFFERENT ACCESS MODES SINCE 2026-08-09 (Tranche 3C) ──
 * countByContractReviewId moved to `WITH SYSTEM_MODE` because its result is written straight back
 * onto the parent as the derived `Contract_Review__c.Latest_Version__c`, so an access-narrowed
 * count does not fail — it CORRUPTS, rewinding a live negotiation's version number. The full
 * argument lives at that method's declaration.
 * countReadsAcrossAccessNarrowing_isTheModeFalsifier below is the permanent falsifier for the
 * mode itself: under the previous `WITH USER_MODE` it threw for a user with no object access, and
 * it now returns a number. That test ALSO pins the residual honestly — the number is still
 * SHARING-narrowed, because SYSTEM_MODE lifts CRUD/FLS and never sharing.
 */
@isTest
private class PsaVersionSelectorTest {

    private static final Integer BULK_N = 251;

    private static Contract_Review__c freshContractReview() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        return TestDataFactory.createContractReview(opp.Id, true);
    }

    /**
     * A Standard User with no DPEG permission set — therefore no CRUD on PSA_Version__c at all.
     *
     * ⚠ Built and inserted inside System.runAs(current user) so the setup-object insert cannot
     * collide with this class's record DML (MIXED_DML_OPERATION). Established idiom in this repo —
     * ContactSelectorTest, GroupNotifierTest, OpportunityApprovalControllerTest all use it.
     */
    private static User insertBareUser() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'psaver' + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User bare = new User(
            FirstName = 'Std',
            LastName = 'PsaVersion',
            Alias = 'pver',
            Email = 'std.psaversion@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bare;
        }
        return bare;
    }

    @isTest
    static void selectByContractReviewId_returnsVersionsWithFields() {
        Contract_Review__c cr = freshContractReview();
        TestDataFactory.createPsaVersions(3, cr.Id, true);

        Test.startTest();
        List<PSA_Version__c> result = PsaVersionSelector.selectByContractReviewId(cr.Id);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'Should return every PSA version for the Contract Review');
        Assert.isNotNull(result[0].Direction__c, 'Direction__c must be populated for the psaVersionLog LWC');
        Assert.isNotNull(result[0].Version_Date__c, 'Version_Date__c must be populated for the psaVersionLog LWC');
    }

    @isTest
    static void selectByContractReviewId_bulk_returnsAll() {
        Contract_Review__c cr = freshContractReview();
        TestDataFactory.createPsaVersions(BULK_N, cr.Id, true);

        Test.startTest();
        List<PSA_Version__c> result = PsaVersionSelector.selectByContractReviewId(cr.Id);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 PSA versions for the Contract Review');
    }

    @isTest
    static void selectByContractReviewId_nullInput_returnsEmpty() {
        Test.startTest();
        List<PSA_Version__c> result = PsaVersionSelector.selectByContractReviewId(null);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Null input returns an empty list, not null');
    }

    @isTest
    static void countByContractReviewId_returnsCount() {
        Contract_Review__c cr = freshContractReview();
        TestDataFactory.createPsaVersions(4, cr.Id, true);

        Test.startTest();
        Integer count = PsaVersionSelector.countByContractReviewId(cr.Id);
        Test.stopTest();

        Assert.areEqual(4, count, 'Count must match the number of PSA versions logged');
    }

    @isTest
    static void countByContractReviewId_nullInput_returnsZero() {
        Test.startTest();
        Integer count = PsaVersionSelector.countByContractReviewId(null);
        Test.stopTest();

        Assert.areEqual(0, count, 'Null input returns 0');
    }

    /**
     * 🔴 THE PERMANENT FALSIFIER FOR THE 2026-08-09 ACCESS-MODE CHANGE, AND IT ASSERTS BOTH WHAT
     * THE FIX CLOSED AND WHAT IT DID NOT.
     *
     * countByContractReviewId feeds PsaVersionService's derived
     * `Contract_Review__c.Latest_Version__c = priorCount + 1` stamp, so an access-narrowed count is
     * not a narrower answer — it is a WRONG one, written back onto a record every other user reads.
     *
     * WHAT THIS PROVES (assertion 1): a user with NO object access at all no longer takes the query
     * down. Under the previous `WITH USER_MODE` this exact call raised
     * `System.QueryException` (no Read on PSA_Version__c), which PsaVersionController converts into
     * its fixed generic "could not be saved" message — so a permission-set redeploy that dropped
     * the object grant would have broken Log Version on BOTH sides of the house. Reverting the
     * method to USER_MODE reds this test on the exception.
     *
     * 🔴 WHAT THIS DELIBERATELY DOES NOT PROVE, AND MUST NOT BE READ AS PROVING (assertion 2): that
     * the count is now CORRECT for a narrowed user. It is not, and it cannot be while the class is
     * `with sharing`. `PSA_Version__c` is `sharingModel Private` with an EMPTY sharing-rules file,
     * so this user — who owns none of the three rows — is still shown 0 of 3. Assertion 2 pins that
     * residual as a KNOWN, MEASURED state rather than leaving it to be rediscovered as a bug: the
     * remedy is a narrow `private without sharing` inner class, which was scoped out of this
     * change. ⚠ If a future change closes the sharing half, this assertion flips to 3 and SHOULD be
     * updated — a red here after such a change is the fix working, not a regression.
     */
    @isTest
    static void countReadsAcrossAccessNarrowing_isTheModeFalsifier() {
        User bare = insertBareUser();
        Contract_Review__c cr = freshContractReview();
        TestDataFactory.createPsaVersions(3, cr.Id, true);

        Integer countAsAdmin = PsaVersionSelector.countByContractReviewId(cr.Id);
        Assert.areEqual(3, countAsAdmin,
            'PRECONDITION: the fixture must carry three versions before the narrowed read means '
            + 'anything');

        Test.startTest();
        Integer countAsBareUser;
        Boolean threw = false;
        System.runAs(bare) {
            try {
                countAsBareUser = PsaVersionSelector.countByContractReviewId(cr.Id);
            } catch (QueryException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isFalse(threw,
            'countByContractReviewId must NOT throw for a user without CRUD on PSA_Version__c. A '
            + 'QueryException here means the method was reverted to WITH USER_MODE — which takes '
            + 'the whole Log Version save down rather than counting. See the method\'s own header: '
            + 'this read is a DERIVED-FIELD input, not a read the user asked for.');
        Assert.areEqual(0, countAsBareUser,
            'KNOWN RESIDUAL, asserted so it is not mistaken for a fix: SYSTEM_MODE lifts CRUD and '
            + 'FLS but NEVER sharing, and this class is `with sharing`. PSA_Version__c is OWD '
            + 'Private with zero sharing rules, so a user who owns none of the rows still counts 0 '
            + 'of 3 — and PsaVersionService would still write Latest_Version__c = 1. Closing this '
            + 'needs a narrow `private without sharing` inner class (the '
            + 'InboundEmailStagingSelector.RoutingReads shape), which was deliberately out of '
            + 'scope. If that lands, this expectation becomes 3.');
    }
}
