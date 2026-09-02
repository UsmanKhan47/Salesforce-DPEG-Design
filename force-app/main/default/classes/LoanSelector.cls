/**
 * Selector for `Loan__c` - the financing record behind checklist group F. Encapsulates ALL SOQL
 * against the object per ARCHITECTURE.md §2 and `.claude/rules/apex-layering-rule.md`.
 *
 * layer=selector.
 *
 * ┌───────────────────────────────────────────────────────────────────────────────────────────┐
 * │ MODE INVENTORY - EVERY METHOD IS `WITH USER_MODE`, AND THAT IS A DELIBERATE CHOICE RATHER  │
 * │ THAN AN OMISSION. Read the METHOD, never the class (ARCHITECTURE.md §2).                   │
 * └───────────────────────────────────────────────────────────────────────────────────────────┘
 * Both callers run because a human clicked something on the checklist screen:
 *   • `LoanService.ensureFor`      <- the user opened the capture dialog on an F item.
 *   • `LoanService.existingByDeal` <- the user clicked Complete on an F item (the capture guard).
 * Neither is a read performed on somebody else's behalf, so ARCHITECTURE.md §2's default applies:
 * a `USER_MODE` throw here reports a REAL provisioning gap and the fix is a permission set.
 *
 * ✅ AND THE GRANT ALREADY EXISTS, WHICH IS WHY THIS IS SAFE ON DEPLOY DAY AND
 * `ChecklistItemSelector.selectByIdsWithDeal` IS NOT. `DPEG_Checklist_Edit` and
 * `DPEG_Checklist_View` shipped in Phase 1 carrying read (and, on Edit, write) on all seven
 * `Loan__c` fields plus `allowRead` / `allowCreate` / `allowEdit` on the object itself - verified
 * 2026-09-02 in `permissionsets/DPEG_Checklist_Edit.permissionset-meta.xml:205-240`. The usual
 * "a Metadata-API-deployed field arrives with FieldPermissions for nobody" hazard was paid for by
 * the schema phase, not deferred into this one. ⚠ If a field is ever ADDED to `Loan__c`, adding it
 * to the SELECT below without adding it to both permission sets takes this whole screen down for
 * everyone with `QueryException: No such column` - an FLS denial wearing a schema error.
 *
 * ⚠ SHARING IS NEVER LIFTED HERE AND MUST NOT BE. `Loan__c` is `Private` OWD with an ordinary
 * LOOKUP to `Transaction__c` - it is NOT `ControlledByParent`, so unlike `Checklist_Item__c` a
 * loan's visibility does NOT follow the deal automatically. That is a real residual and it fails
 * CLOSED in both callers: `ensureFor` treats an unreadable existing loan as absent, and the
 * completion guard treats an unresolvable loan as "the value is not on file" and refuses the
 * completion rather than waving it through.
 *
 * @see force-app/main/default/classes/LoanService.cls (the only caller)
 * @see agent-output/design-transaction-fsd-gaps.md §4.3, §5.9
 */
public with sharing class LoanSelector {

    /**
     * The loans on the supplied deals, oldest first.
     *
     * 🔴 RETURNS A LIST PER DEAL, NOT ONE ROW PER DEAL, AND THE CALLER RESOLVES THE COLLISION.
     * `Loan__c.Transaction__c` is an ordinary lookup with no uniqueness constraint, so two loans on
     * one deal is a state the schema permits (a refinance, a second-position loan, or simply two
     * people opening the capture dialog at the same moment). Collapsing that here with a silent
     * `LIMIT 1` would make the capture dialog write to an arbitrary one of them and look like it
     * worked. `LoanService.ensureFor` picks the OLDEST deterministically and says so.
     *
     * ⚠ ORDERED BY `CreatedDate` THEN `Id`. `CreatedDate` alone is not a total order - two rows
     * inserted by one DML statement share it to the second - and an unstable order would point the
     * capture dialog at a different loan on different page loads.
     *
     * ⚠ EVERY SELECTED CUSTOM FIELD IS AN FLS DEPENDENCY under `USER_MODE`. The list is exactly
     * the fields `ChecklistCaptureDefProvider` can name plus the two the dialog needs to render
     * (`Id`, `Name`); nothing is selected speculatively.
     *
     * @param transactionIds parent deal ids; null/empty-safe.
     * @return matching loans, ordered; an empty list when the input is empty, nothing matches, or
     *         the running user cannot see the rows (never null).
     * @example
     * List<Loan__c> loans = LoanSelector.selectByTransactionIds(dealIds);
     */
    public static List<Loan__c> selectByTransactionIds(Set<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return new List<Loan__c>();
        }
        return [
            SELECT Id, Name, Transaction__c, Lender_Name__c, Loan_Amount__c, Term_Months__c,
                   Interest_Rate_Pct__c, Bank_Account_Type__c, Auto_Payment_Status__c,
                   Commitment_Date__c
            FROM Loan__c
            WHERE Transaction__c IN :transactionIds
            WITH USER_MODE
            ORDER BY CreatedDate ASC, Id ASC
        ];
    }
}
