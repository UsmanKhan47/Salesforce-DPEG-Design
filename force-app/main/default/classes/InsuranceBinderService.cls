/**
 * Provisions and resolves the one `Insurance_Binder__c` behind a deal's checklist group G.
 *
 * layer=service. ZERO inline SOQL - the single read is
 * `InsuranceBinderSelector.selectByTransactionIds`. Deliberately the exact twin of `LoanService`;
 * that class's header carries the full argument for every decision repeated here (LDS writes the
 * captured values, Apex only creates the row; lazy provisioning rather than eager at fan-out;
 * read-then-create idempotency with an accepted race; `USER_MODE` on the insert). Only the
 * differences are stated below, so the two headers cannot drift into two different stories.
 *
 * ── DIFFERENCE 1: GROUP G IS UNCONDITIONAL ─────────────────────────────────────────────────
 * `LoanService` inherits its "only on loan deals" condition from
 * `Task_Group_Def__mdt.Condition_Field__c` on group F. Group G has no condition field, so every
 * fanned-out deal has one, and every deal reaching the insurance steps gets a binder. There is no
 * equivalent gate to inherit and none is invented here.
 *
 * ── DIFFERENCE 2: `Is_Bound__c` IS DERIVED AND MUST NEVER BE WRITTEN ───────────────────────
 * 🔴 `Is_Bound__c` is a FORMULA checkbox over `Bound_Date__c` (`NOT(ISBLANK(Bound_Date__c))`). It
 * is absent from `ChecklistCaptureDefProvider`'s G5 field list and absent from every write payload
 * in this class, and both absences are load-bearing:
 *   • Putting it in the capture dialog would put a non-writable field in a
 *     `lightning-record-edit-form`, and the save fails.
 *   • Requiring it as the completion gate would require a value nobody can enter.
 * G5 therefore requires `Bound_Date__c`, and `Is_Bound__c` follows from it automatically and can
 * never disagree with it. ⚠ It must also be granted `editable=false` in every permission set -
 * `editable=true` on a formula field fails the DEPLOY, not the runtime.
 *
 * ── DIFFERENCE 3: MULTIPLE BINDERS PER DEAL ARE ORDINARY, NOT A RACE ───────────────────────
 * Two `Loan__c` rows on one deal is almost always a lost race. Two `Insurance_Binder__c` rows is
 * normal CRE practice - property, general liability and flood are commonly separate binders from
 * separate carriers. So the "oldest wins" rule here is not a race repair, it is a stable choice of
 * WHICH binder the checklist tracks, and the others live perfectly legitimately beside it in the
 * deal's related list. ⚠ That means a future requirement of the form "the checklist should track
 * the FLOOD binder" is a real requirement, not a bug report, and it needs a discriminating field
 * on the object rather than a change to this ordering.
 *
 * @see force-app/main/default/classes/LoanService.cls (the twin, and the fuller header)
 * @see force-app/main/default/classes/ChecklistCaptureService.cls (the only caller)
 * @see agent-output/design-transaction-fsd-gaps.md §4.4, §5.9
 */
public with sharing class InsuranceBinderService {

    /**
     * Resolves the deals' binders, creating one for any deal that has none.
     *
     * ⚠ `AccessLevel.USER_MODE` on the insert. `DPEG_Checklist_Edit` grants `allowCreate=true` on
     * `Insurance_Binder__c` plus write on every non-formula field (verified 2026-09-02). A
     * principal without that grant is refused, which is correct: opening a dialog must not let a
     * read-only viewer create deal records.
     *
     * @param transactionIds deals whose binder is needed; null/empty-safe (returns an empty map).
     * @return Map of deal Id -> the deal's `Insurance_Binder__c`. A deal is ABSENT only when its
     *         binder could neither be read nor created; the caller must fail closed on a missing
     *         key, never treat it as "no capture needed".
     * @throws System.DmlException on a platform save failure, including a CRUD/FLS denial.
     * @example
     * Map&lt;Id, Insurance_Binder__c&gt; binders = InsuranceBinderService.ensureFor(dealIds);
     */
    public static Map<Id, Insurance_Binder__c> ensureFor(Set<Id> transactionIds) {
        Map<Id, Insurance_Binder__c> byDeal = existingByDeal(transactionIds);
        if (transactionIds == null || transactionIds.isEmpty()) {
            return byDeal;
        }

        List<Insurance_Binder__c> toCreate = new List<Insurance_Binder__c>();
        List<Id> createdForDeals = new List<Id>();
        for (Id dealId : transactionIds) {
            if (byDeal.containsKey(dealId)) {
                continue;
            }
            toCreate.add(new Insurance_Binder__c(Transaction__c = dealId));
            createdForDeals.add(dealId);
        }
        if (toCreate.isEmpty()) {
            return byDeal;
        }

        Database.insert(toCreate, true, AccessLevel.USER_MODE);
        for (Integer i = 0; i < toCreate.size(); i++) {
            byDeal.put(createdForDeals[i], toCreate[i]);
        }
        return byDeal;
    }

    /**
     * The deals' existing binders, WITHOUT creating anything - the read behind the group G
     * completion guard, which must not provision a row as a side effect of asking whether one is
     * filled in.
     *
     * ⚠ `ensureFor` calls this method rather than reading for itself, so exactly one place decides
     * which binder is the deal's binder. If the guard and the dialog ever chose differently, a user
     * who filled the dialog in correctly would still be refused.
     *
     * @param transactionIds deals to resolve; null/empty-safe.
     * @return Map of deal Id -> oldest `Insurance_Binder__c`; deals with none are ABSENT.
     * @example
     * Map&lt;Id, Insurance_Binder__c&gt; binders = InsuranceBinderService.existingByDeal(dealIds);
     */
    public static Map<Id, Insurance_Binder__c> existingByDeal(Set<Id> transactionIds) {
        Map<Id, Insurance_Binder__c> byDeal = new Map<Id, Insurance_Binder__c>();
        for (Insurance_Binder__c binder : InsuranceBinderSelector.selectByTransactionIds(transactionIds)) {
            if (binder.Transaction__c == null || byDeal.containsKey(binder.Transaction__c)) {
                continue;
            }
            byDeal.put(binder.Transaction__c, binder);
        }
        return byDeal;
    }
}
