/**
 * Unit tests for `DispositionChildDetailsController`.
 *
 * ── WHY THERE IS NO 251-RECORD BULK TEST HERE, DELIBERATELY ─────────────────────────────────
 * `.claude/rules/bulk-test-rule.md` mandates 251 records for triggers, batch jobs, queueables and
 * DML-performing services — the number exists to force a SECOND trigger batch chunk and expose
 * SOQL-in-loop bugs. This controller is none of those: it is a `cacheable=true` READ that runs
 * exactly one `LIMIT 1` selector query per invocation, with no loop and no DML anywhere in the
 * call chain. 251 dispositions would execute the identical single code path 1 time, not 251, and
 * prove nothing a 1-record fixture does not. Same reasoning the content-selector tests in this
 * repo record for their own reduced volumes.
 *
 * The behaviours that DO matter on this class are the three answers it can give and the two ways
 * it can refuse, and each has a test below:
 *   1. a real child exists           → its Id
 *   2. the sale has no child yet     → null (the LWC's honest empty state)
 *   3. no parent Id at all           → null
 *   4. the parent Id is not a sale   → AuraHandledException naming Disposition
 *   5. the child object is unknown   → AuraHandledException naming the two supported objects
 *
 * ⚠ 4 AND 5 MUST NOT SHARE A MESSAGE WITH THE GENERIC READ FAILURE, and the assertions check
 * that explicitly. If a guard ever slips inside the controller's `try`, its refusal is rewritten
 * as "contact your administrator" and the next person to hit it goes and edits a permission set
 * to fix a FlexiPage typo. The message text is the only signal that distinguishes the two.
 */
@isTest
private class DispositionChildDetailsControllerTest {
    private static final String LOI_OBJECT = 'LOI__c';
    private static final String PSA_OBJECT = 'Contract_Review__c';

    @TestSetup
    static void setupTestData() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    /**
     * A fresh Disposition on the shared scaffold asset. Created at 'Disposition Readiness' by the
     * factory, which is what keeps the "no child yet" tests honest — the stage-entry auto-create
     * only fires on entry to the LOI / PSA stages, so nothing is created behind our back.
     */
    private static Disposition__c newDisposition() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        return TestDataFactory.createDisposition(asset.Id, true);
    }

    @isTest
    static void getPrimaryChildId_loiExists_returnsThatLoiId() {
        Disposition__c sale = newDisposition();
        LOI__c loi = TestDataFactory.createDispositionLoi(sale.Id, true);

        Test.startTest();
        Id resolved = DispositionChildDetailsController.getPrimaryChildId(sale.Id, LOI_OBJECT);
        Test.stopTest();

        Assert.areEqual(
            loi.Id,
            resolved,
            'The LOI branch must resolve the LOI parented to this exact Disposition'
        );
    }

    @isTest
    static void getPrimaryChildId_contractReviewExists_returnsThatContractReviewId() {
        Disposition__c sale = newDisposition();
        Contract_Review__c psa = TestDataFactory.createDispositionContractReview(sale.Id, true);

        Test.startTest();
        Id resolved = DispositionChildDetailsController.getPrimaryChildId(sale.Id, PSA_OBJECT);
        Test.stopTest();

        Assert.areEqual(
            psa.Id,
            resolved,
            'The Contract Review branch must resolve the PSA parented to this exact Disposition'
        );
    }

    /**
     * The empty state, on BOTH branches in one test so a future change that fixes one and breaks
     * the other cannot pass. `null` here is a real answer, not a swallowed failure — see the
     * controller header on why the two are kept distinguishable.
     */
    @isTest
    static void getPrimaryChildId_noChildOnEitherObject_returnsNullNotAnError() {
        Disposition__c sale = newDisposition();

        Test.startTest();
        Id loiId = DispositionChildDetailsController.getPrimaryChildId(sale.Id, LOI_OBJECT);
        Id psaId = DispositionChildDetailsController.getPrimaryChildId(sale.Id, PSA_OBJECT);
        Test.stopTest();

        Assert.isNull(loiId, 'A sale with no LOI must answer null, never throw');
        Assert.isNull(psaId, 'A sale with no PSA must answer null, never throw');
    }

    @isTest
    static void getPrimaryChildId_nullDispositionId_returnsNull() {
        Test.startTest();
        Id resolved = DispositionChildDetailsController.getPrimaryChildId(null, LOI_OBJECT);
        Test.stopTest();

        Assert.isNull(
            resolved,
            'A null parent Id is the pre-save / mis-drop case and must render as empty, not error'
        );
    }

    /**
     * ⚠ A REAL Contact Id, not a malformed string. A malformed Id literal fails to coerce at the
     * CALL SITE and never reaches the method, so the guard would look covered while being
     * untested — measured in this repo.
     */
    @isTest
    static void getPrimaryChildId_foreignParentType_throwsNamingDisposition() {
        Contact notASale = TestDataFactory.createContact(null, true);
        Boolean threw = false;

        Test.startTest();
        try {
            DispositionChildDetailsController.getPrimaryChildId(notASale.Id, LOI_OBJECT);
            Assert.fail('A Contact Id must not be accepted as a Disposition Id');
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(
                e.getMessage().contains('Disposition'),
                'The refusal must NAME the expected parent object — a wiring mistake and a '
                    + 'permission gap need different fixes and only the text distinguishes them'
            );
            Assert.isFalse(
                e.getMessage().contains('Refresh the page'),
                'and must not be the generic read-failure text, which would mean the guard had '
                    + 'fallen inside the try and been swallowed'
            );
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The foreign-parent guard must fire');
    }

    @isTest
    static void getPrimaryChildId_unsupportedChildObject_throwsNamingBothSupportedObjects() {
        Disposition__c sale = newDisposition();
        Boolean threw = false;

        Test.startTest();
        try {
            DispositionChildDetailsController.getPrimaryChildId(sale.Id, 'NDA__c');
            Assert.fail('Only LOI__c and Contract_Review__c may be resolved by this controller');
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(
                e.getMessage().contains('LOI__c') && e.getMessage().contains('Contract_Review__c'),
                'The refusal must name BOTH supported objects so an admin can fix the FlexiPage '
                    + 'property without reading the Apex'
            );
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The unsupported-child guard must fire');
    }

    /**
     * 🔴 THIS TEST ALREADY EARNED ITS KEEP — it FAILED on the first check-only run and the code
     * was wrong, not the test. The controller keyed its allow-list on the real API names under a
     * comment asserting that Apex String-keyed `Map.get` is case-insensitive. It is NOT: `==` on
     * String is case-insensitive, a String-keyed Map is case-SENSITIVE, and `get('loi__c')`
     * returned null. Tolerating case is now explicit (lower-cased keys + a lower-cased lookup),
     * and this is the pin that stops it regressing to the "obvious" version again.
     */
    @isTest
    static void getPrimaryChildId_childObjectNameIsCaseInsensitive() {
        Disposition__c sale = newDisposition();
        LOI__c loi = TestDataFactory.createDispositionLoi(sale.Id, true);

        Test.startTest();
        Id resolved = DispositionChildDetailsController.getPrimaryChildId(sale.Id, 'loi__c');
        Test.stopTest();

        Assert.areEqual(loi.Id, resolved, 'A lower-case API name must resolve the same branch');
    }
}
