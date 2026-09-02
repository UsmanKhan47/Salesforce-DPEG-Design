/**
 * Provisions and resolves the one `Loan__c` behind a deal's checklist group F.
 *
 * layer=service. ZERO inline SOQL - the single read is `LoanSelector.selectByTransactionIds`.
 * Every public method takes a COLLECTION (ARCHITECTURE.md §2); the controller passes a singleton
 * because a user opens one capture dialog at a time, but nothing here is shaped around that and
 * the cost is one SOQL plus at most one DML for a set of ANY size.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS SERVICE DOES NOT WRITE THE CAPTURED FIELDS, AND THAT IS THE CENTRAL DESIGN DECISION
 *    OF PHASE 5. IT CREATES THE ROW; LIGHTNING DATA SERVICE WRITES THE VALUES.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ARCHITECTURE.md §5 ranks LDS first and puts imperative Apex last, "only when LDS cannot express
 * the query". Writing `Lender_Name__c` or `Bank_Account_Type__c` is the textbook case §5 reserves
 * for `lightning-record-edit-form`: a single record, standard fields, standard validation. So the
 * capture dialog binds a `lightning-record-edit-form` to the Id this service returns, and the
 * seven loan fields are never named in an Apex write payload anywhere in this repo.
 *
 * Three things follow, and they are the reason this is not merely tidier:
 *   • FLS AND VALIDATION ARE THE PLATFORM'S. An Apex writer would have to re-check field
 *     accessibility by hand, and this org has already shipped the failure where it did not
 *     (a permission-set-granted field silently dropped from a form payload).
 *   • THE RESTRICTED PICKLISTS POLICE THEMSELVES. `Bank_Account_Type__c` and
 *     `Auto_Payment_Status__c` are both restricted. An Apex writer taking a String from the client
 *     could send a value the picklist refuses, producing
 *     `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` from inside a completion the user thought was
 *     about ticking a box. A combobox rendered by `lightning-input-field` can only offer real
 *     values.
 *   • THERE IS NO SECOND WRITER TO GO STALE. Adding a field to `Loan__c` later needs a permission
 *     grant and one entry in `ChecklistCaptureDefProvider` - no Apex change at all.
 *
 * ── WHY LAZY PROVISIONING, NOT EAGER AT FAN-OUT ────────────────────────────────────────────
 * The obvious alternative is to create the `Loan__c` inside `ChecklistFanoutService.fanOutNow`,
 * beside the group F checklist it belongs to. Rejected, for a measured reason rather than a
 * preference: that method carries a re-derived governor budget (4 DML statements, 2 SOQL, and a
 * row count sized against `CHUNK_SIZE = 50`) which is pinned by in-context counter assertions in
 * its own test class. Adding a fifth statement and 50 more rows per chunk would move numbers that
 * three test methods assert exactly, in a class whose header records that the previous sizing
 * understated its own SOQL cost fourfold. Provisioning here instead costs ONE row, created the
 * first time a human actually opens an F capture dialog, and leaves that budget untouched.
 *
 * ⚠ THE VISIBLE CONSEQUENCE, STATED SO IT IS NOT REPORTED AS A BUG: the deal's Loans related list
 * is EMPTY until somebody opens an F capture dialog. It is not empty because the fan-out failed.
 *
 * ── `Loan_Required__c` IS NOT CHECKED HERE, ON PURPOSE ─────────────────────────────────────
 * The brief notes that a `Loan__c` exists only when `Transaction__c.Loan_Required__c` is true -
 * "the same condition that gates checklist group F". That condition is ALREADY ENFORCED, one layer
 * up and in data rather than code: `Task_Group_Def__mdt.Condition_Field__c = 'Loan_Required__c'` on
 * group F, so `ChecklistFanoutService` creates group F only on loan deals, and
 * `ChecklistFanoutService.reconcile` adds or removes it when the flag flips. An F item therefore
 * CANNOT exist on a no-loan deal, and the only caller of this service is the capture path for an F
 * item. Re-reading `Loan_Required__c` here would add a `Transaction__c` query to prove something
 * the caller's own existence already proves, and would introduce a SECOND definition of the
 * condition that could drift from the CMDT row.
 *
 * @see force-app/main/default/classes/ChecklistCaptureService.cls (the only caller)
 * @see force-app/main/default/classes/InsuranceBinderService.cls (the group G twin)
 * @see agent-output/design-transaction-fsd-gaps.md §4.3, §5.9
 */
public with sharing class LoanService {

    /**
     * Resolves the deals' loans, creating one for any deal that has none.
     *
     * 🔴 IDEMPOTENT, AND THE IDEMPOTENCY IS A READ-THEN-CREATE, NOT AN UPSERT ON AN EXTERNAL ID.
     * `Loan__c` has no external id and no unique field, so `Database.upsert` has nothing to key on.
     * A read-then-create has a genuine race - two users opening the dialog in the same second can
     * both see zero loans and both insert one - and the race is ACCEPTED rather than locked out:
     *   • A `FOR UPDATE` lock on the parent deal would serialise unrelated checklist work behind
     *     one capture dialog, which is the trade `ContentPublicationBudget`'s header rejects for
     *     the same reason.
     *   • The consequence of losing the race is TWO loan rows, not lost data. `selectByTransactionIds`
     *     orders deterministically and this method takes the OLDEST, so both users converge on the
     *     same record from their next page load onward, and the orphan is visible in the deal's
     *     Loans related list rather than hidden.
     * ⚠ Do not "fix" this with a lock without pricing the serialisation first.
     *
     * ⚠ `AccessLevel.USER_MODE` ON THE INSERT, DELIBERATELY, AND IT IS SAFE ON DEPLOY DAY.
     * `DPEG_Checklist_Edit` grants `allowCreate=true` on `Loan__c` plus write on every field
     * (verified 2026-09-02). A principal who lacks that grant SHOULD be refused: creating a
     * financing record is not a side effect of reading a checklist, it is a write, and
     * ARCHITECTURE.md §2 is explicit that a USER_MODE failure on a path the user asked for is the
     * correct outcome and the fix is a permission set. There is no SYSTEM_MODE anywhere in this
     * class and none must be added - doing so would let a read-only viewer silently create deal
     * records by opening a dialog.
     *
     * @param transactionIds deals whose loan is needed; null/empty-safe (returns an empty map).
     * @return Map of deal Id -> the deal's `Loan__c` (existing or just created). A deal is ABSENT
     *         from the map only when its loan could neither be read nor created; the caller must
     *         treat a missing key as unresolved and fail closed, never as "no capture needed".
     * @throws System.DmlException on a platform save failure, including a CRUD/FLS denial.
     * @example
     * Map&lt;Id, Loan__c&gt; loans = LoanService.ensureFor(new Set&lt;Id&gt;{ dealId });
     */
    public static Map<Id, Loan__c> ensureFor(Set<Id> transactionIds) {
        Map<Id, Loan__c> byDeal = existingByDeal(transactionIds);
        if (transactionIds == null || transactionIds.isEmpty()) {
            return byDeal;
        }

        List<Loan__c> toCreate = new List<Loan__c>();
        List<Id> createdForDeals = new List<Id>();
        for (Id dealId : transactionIds) {
            if (byDeal.containsKey(dealId)) {
                continue;
            }
            toCreate.add(new Loan__c(Transaction__c = dealId));
            createdForDeals.add(dealId);
        }
        if (toCreate.isEmpty()) {
            return byDeal;
        }

        // One statement for the whole set - never one insert per deal.
        Database.insert(toCreate, true, AccessLevel.USER_MODE);
        for (Integer i = 0; i < toCreate.size(); i++) {
            byDeal.put(createdForDeals[i], toCreate[i]);
        }
        return byDeal;
    }

    /**
     * The deals' existing loans, WITHOUT creating anything. The read behind the group F completion
     * guard, which must never provision a row as a side effect of asking whether one is filled in.
     *
     * ⚠ OLDEST WINS, and it must be the SAME choice `ensureFor` makes or the guard would inspect a
     * different record from the one the dialog wrote to - a defect that would show as "I filled it
     * in and it still refuses me". `ensureFor` calls THIS method rather than reading for itself,
     * so there is exactly one place that decides which loan is the deal's loan.
     *
     * @param transactionIds deals to resolve; null/empty-safe.
     * @return Map of deal Id -> oldest `Loan__c`; deals with no readable loan are ABSENT.
     * @example
     * Map&lt;Id, Loan__c&gt; loans = LoanService.existingByDeal(dealIds);
     */
    public static Map<Id, Loan__c> existingByDeal(Set<Id> transactionIds) {
        Map<Id, Loan__c> byDeal = new Map<Id, Loan__c>();
        for (Loan__c loan : LoanSelector.selectByTransactionIds(transactionIds)) {
            if (loan.Transaction__c == null || byDeal.containsKey(loan.Transaction__c)) {
                // Ordered oldest-first by the selector, so the first one seen wins and every later
                // duplicate is skipped without a second comparison.
                continue;
            }
            byDeal.put(loan.Transaction__c, loan);
        }
        return byDeal;
    }
}
