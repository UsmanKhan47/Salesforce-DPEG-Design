/**
 * Tests OnboardingTaskDefProvider — the CMDT read behind the PM onboarding checklist fan-out.
 *
 * ═══ ⚠ WHAT THIS CLASS CAN AND CANNOT PROVE, STATED SO IT IS NOT ASSUMED ═══
 * `Onboarding_Task_Def__mdt` records CANNOT be inserted in an Apex test, and the 45 production
 * rows are NOT in the repo — the customMetadata directory glob is force-ignored because
 * file-based CMDT record deploys throw UNKNOWN_EXCEPTION in this org, so they are loaded
 * asynchronously by `scripts/load-onboarding-task-defs.apex`. `getAll()` therefore returns
 * whatever the TARGET ORG happens to hold, which is:
 *   - 45 rows in an org where the loader has run;
 *   - ZERO rows in a freshly built scratch org, or in one where the async deploy has not
 *     finished yet.
 *
 * An assertion on the row COUNT or on specific SUBJECTS would therefore be org-dependent and
 * would red for reasons having nothing to do with this class. So this class asserts only what
 * is true under BOTH states — the ordering contract and the null/empty contract — and the
 * SORT itself is proved directly against the comparator with in-memory rows, which is the one
 * thing that is deterministic everywhere.
 *
 * The 45-row count is verified instead by post-deploy gate 2 (read the CMDT back after the
 * loader completes), which is where an org-state fact belongs.
 */
@isTest
private class OnboardingTaskDefProviderTest {

    /**
     * The ordering contract, proved against the comparator with in-memory rows so it holds in
     * an org with zero CMDT records. Category ascending, then Sequence ascending.
     */
    @isTest
    static void comparatorOrdersByCategoryThenSequence() {
        List<Onboarding_Task_Def__mdt> defs = new List<Onboarding_Task_Def__mdt>{
            new Onboarding_Task_Def__mdt(Category__c = 'Leasing', Sequence__c = 2, Subject__c = 'L2'),
            new Onboarding_Task_Def__mdt(Category__c = 'Property Set up', Sequence__c = 7, Subject__c = 'P7'),
            new Onboarding_Task_Def__mdt(Category__c = 'Leasing', Sequence__c = 1, Subject__c = 'L1'),
            new Onboarding_Task_Def__mdt(Category__c = 'Property Set up', Sequence__c = 1, Subject__c = 'P1')
        };

        Test.startTest();
        defs.sort(new OnboardingTaskDefProvider.CategorySequenceComparator());
        Test.stopTest();

        Assert.areEqual('L1', defs[0].Subject__c, 'Leasing sorts before Property Set up');
        Assert.areEqual('L2', defs[1].Subject__c, 'and within Leasing, sequence 1 before 2');
        Assert.areEqual('P1', defs[2].Subject__c, 'then Property Set up, sequence ascending');
        Assert.areEqual('P7', defs[3].Subject__c, 'sequence 7 last');
    }

    /**
     * NULLS FIRST on both keys — matching SOQL `ORDER BY ... ASC` semantics, which is what this
     * comparator replaced. Worth pinning separately because a naive comparator that returns 0
     * for a null pair silently makes the order non-deterministic rather than obviously wrong.
     */
    @isTest
    static void comparatorPutsNullsFirstOnBothKeys() {
        List<Onboarding_Task_Def__mdt> defs = new List<Onboarding_Task_Def__mdt>{
            new Onboarding_Task_Def__mdt(Category__c = 'Leasing', Sequence__c = 1, Subject__c = 'named'),
            new Onboarding_Task_Def__mdt(Category__c = null, Sequence__c = 9, Subject__c = 'noCategory'),
            new Onboarding_Task_Def__mdt(Category__c = 'Leasing', Sequence__c = null, Subject__c = 'noSequence')
        };

        Test.startTest();
        defs.sort(new OnboardingTaskDefProvider.CategorySequenceComparator());
        Test.stopTest();

        Assert.areEqual('noCategory', defs[0].Subject__c, 'a null Category sorts first');
        Assert.areEqual('noSequence', defs[1].Subject__c, 'then a null Sequence inside its category');
        Assert.areEqual('named', defs[2].Subject__c, 'then the fully populated row');

        // Equal-pair branch: two identical rows compare 0 and neither is dropped.
        List<Onboarding_Task_Def__mdt> equalPair = new List<Onboarding_Task_Def__mdt>{
            new Onboarding_Task_Def__mdt(Category__c = 'Leasing', Sequence__c = 1, Subject__c = 'a'),
            new Onboarding_Task_Def__mdt(Category__c = 'Leasing', Sequence__c = 1, Subject__c = 'b')
        };
        equalPair.sort(new OnboardingTaskDefProvider.CategorySequenceComparator());
        Assert.areEqual(2, equalPair.size(), 'Two equal rows both survive the sort');
    }

    /**
     * The public entry point never returns null and never throws, in EITHER org state — the
     * only contract every caller depends on. `OnboardingFanoutService` treats an empty list as
     * "not configured yet" and deliberately declines to flag the Onboarding, so an exception
     * here would be strictly worse than an empty result.
     */
    @isTest
    static void getAllOrderedIsNeverNullAndIsSortedInWhateverOrgItRunsIn() {
        Test.startTest();
        List<Onboarding_Task_Def__mdt> defs = OnboardingTaskDefProvider.getAllOrderedByCategoryAndSequence();
        Test.stopTest();

        Assert.isNotNull(defs,
            'Never null — an org whose async CMDT loader has not finished must get an empty list, '
            + 'not a NullPointerException inside a queueable nobody is watching');

        // Whatever the org holds, it must come back ordered. Vacuously true at 0 or 1 rows,
        // which is correct: this asserts the CONTRACT, and the comparator itself is proved above.
        // ⚠ Re-uses the comparator rather than hand-rolling `<=`: Apex has no relational
        // operator on String, and a bare `<=` on a null Decimal is a NullPointerException.
        OnboardingTaskDefProvider.CategorySequenceComparator comparator =
            new OnboardingTaskDefProvider.CategorySequenceComparator();
        for (Integer i = 1; i < defs.size(); i++) {
            Assert.isTrue(comparator.compare(defs[i - 1], defs[i]) <= 0,
                'Rows must come back ordered by Category then Sequence; row ' + (i - 1)
                + ' sorts after row ' + i);
        }
    }
}
