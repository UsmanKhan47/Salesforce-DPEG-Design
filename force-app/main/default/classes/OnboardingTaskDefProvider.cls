/**
 * Provider for the Onboarding_Task_Def__mdt custom metadata type (the 45 PM
 * onboarding checklist item definitions, loaded by
 * scripts/load-onboarding-task-defs.apex).
 *
 * NOT A SELECTOR, and the distinction is deliberate rather than an oversight:
 * Custom Metadata is not subject to FLS or sharing, so `WITH USER_MODE` is inert
 * on `__mdt`, and the sf-apex rule mandates `getAll()` / `getInstance()` over
 * SOQL. Reading CMDT through `getAll()` also costs ZERO of the 100 SOQL queries,
 * which is load-bearing here: OnboardingFanoutQueueable calls this once per chunk
 * inside a job that is already spending its query budget on the Onboarding read.
 *
 * `getAll()` populates every non-long-text field on each record, so callers get
 * all of Category__c / Subject__c / Sequence__c / Owner_Label__c /
 * Source_System__c / Due_Day_Offset__c / Default_Status__c / Conditional__c
 * regardless of which subset they read.
 *
 * ⚠ THE 45 ROWS ARE NOT IN THE REPO AND CANNOT BE. `.forceignore` excludes
 * the customMetadata directory glob because a file-based CMDT record deploy throws
 * UNKNOWN_EXCEPTION in this org; the rows are loaded by
 * `scripts/load-onboarding-task-defs.apex` via the Apex Metadata API, which is
 * ASYNCHRONOUS. So `getAll()` returns an EMPTY map in any org where that loader
 * has not yet finished. Every caller must treat empty as "not configured yet"
 * and do nothing, never as "this Onboarding has no checklist".
 *
 * @see force-app/main/default/classes/TransactionTaskDefProvider.cls (the mirrored pattern)
 * @see force-app/main/default/classes/OnboardingFanoutService.cls (sole production caller)
 */
public with sharing class OnboardingTaskDefProvider {

    /**
     * All Onboarding_Task_Def__mdt records ordered by Category__c then Sequence__c
     * (both ascending, nulls first — SOQL `ORDER BY` ASC semantics).
     *
     * ⚠ `Sequence__c` is GLOBAL 1..45, not per-category, so the category key is
     * effectively a no-op tie-break on today's data. It is sorted on anyway
     * because the checklist is RENDERED grouped by category, and a future data
     * load that restarts the sequence inside each category must not silently
     * interleave the groups.
     *
     * @return Ordered list of checklist definitions; an EMPTY list when none are
     *         configured (see the class header — that is a real, expected state
     *         in a freshly built org), never null.
     * @example
     * for (Onboarding_Task_Def__mdt d : OnboardingTaskDefProvider.getAllOrderedByCategoryAndSequence()) { ... }
     */
    public static List<Onboarding_Task_Def__mdt> getAllOrderedByCategoryAndSequence() {
        List<Onboarding_Task_Def__mdt> defs = Onboarding_Task_Def__mdt.getAll().values();
        defs.sort(new CategorySequenceComparator());
        return defs;
    }

    /** Orders by Category__c, then Sequence__c — both ascending, nulls first. */
    @TestVisible
    private class CategorySequenceComparator implements System.Comparator<Onboarding_Task_Def__mdt> {
        public Integer compare(Onboarding_Task_Def__mdt first, Onboarding_Task_Def__mdt second) {
            Integer byCategory = compareStrings(first.Category__c, second.Category__c);
            if (byCategory != 0) {
                return byCategory;
            }
            return compareDecimals(first.Sequence__c, second.Sequence__c);
        }

        private Integer compareStrings(String a, String b) {
            if (a == b) {
                return 0;
            }
            if (a == null) {
                return -1;
            }
            if (b == null) {
                return 1;
            }
            return a.compareTo(b);
        }

        private Integer compareDecimals(Decimal a, Decimal b) {
            if (a == b) {
                return 0;
            }
            if (a == null) {
                return -1;
            }
            if (b == null) {
                return 1;
            }
            return a > b ? 1 : -1;
        }
    }
}
