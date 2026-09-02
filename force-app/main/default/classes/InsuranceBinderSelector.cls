/**
 * Selector for `Insurance_Binder__c` - the coverage record behind checklist group G. Encapsulates
 * ALL SOQL against the object per ARCHITECTURE.md §2 and `.claude/rules/apex-layering-rule.md`.
 *
 * layer=selector. Deliberately the exact twin of `LoanSelector`; read that class's header for the
 * mode and sharing reasoning, which applies here unchanged, and only the differences are restated
 * below.
 *
 * ┌───────────────────────────────────────────────────────────────────────────────────────────┐
 * │ MODE - `WITH USER_MODE`. Both callers (`InsuranceBinderService.ensureFor` and the group G   │
 * │ completion guard) run because a human clicked something on the checklist screen.            │
 * └───────────────────────────────────────────────────────────────────────────────────────────┘
 * The Phase 1 permission pass granted every `Insurance_Binder__c` field on `DPEG_Checklist_View`
 * and `DPEG_Checklist_Edit` (verified 2026-09-02,
 * `permissionsets/DPEG_Checklist_Edit.permissionset-meta.xml:170-200`), so USER_MODE is safe on
 * deploy day.
 *
 * ⚠ `Is_Bound__c` IS A FORMULA (`NOT(ISBLANK(Bound_Date__c))`). It is SELECTED - a formula is
 * readable and the screen wants it - but it must never appear in a write payload, and it must be
 * granted `editable=false` in every permission set. `editable=true` on a formula field fails the
 * DEPLOY, not the runtime.
 *
 * ⚠ UNLIKE GROUP F, GROUP G IS UNCONDITIONAL. Every fanned-out deal has a group G, so every deal
 * that reaches the insurance steps gets a binder. There is no `Loan_Required__c`-shaped gate to
 * inherit here, which is why `InsuranceBinderService.ensureFor` takes deal ids with no condition
 * check of its own.
 *
 * @see force-app/main/default/classes/InsuranceBinderService.cls (the only caller)
 * @see force-app/main/default/classes/LoanSelector.cls (the twin, and the fuller header)
 * @see agent-output/design-transaction-fsd-gaps.md §4.4, §5.9
 */
public with sharing class InsuranceBinderSelector {

    /**
     * The binders on the supplied deals, oldest first.
     *
     * 🔴 A LIST PER DEAL, NOT ONE ROW PER DEAL. `Insurance_Binder__c.Transaction__c` is an ordinary
     * lookup with no uniqueness constraint, and more than one binder per deal is a legitimate CRE
     * state (property, liability and flood are commonly separate binders). The caller picks the
     * OLDEST deterministically; it does not assume there is only one.
     *
     * ⚠ ORDERED BY `CreatedDate` THEN `Id` for the same total-order reason as `LoanSelector`.
     *
     * @param transactionIds parent deal ids; null/empty-safe.
     * @return matching binders, ordered; an empty list when the input is empty, nothing matches, or
     *         the running user cannot see the rows (never null).
     * @example
     * List<Insurance_Binder__c> binders = InsuranceBinderSelector.selectByTransactionIds(dealIds);
     */
    public static List<Insurance_Binder__c> selectByTransactionIds(Set<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return new List<Insurance_Binder__c>();
        }
        return [
            SELECT Id, Name, Transaction__c, Carrier_Name__c, Policy_Number__c, Coverage_Amount__c,
                   Binding_Deadline_Date__c, Bound_Date__c, Is_Bound__c
            FROM Insurance_Binder__c
            WHERE Transaction__c IN :transactionIds
            WITH USER_MODE
            ORDER BY CreatedDate ASC, Id ASC
        ];
    }
}
