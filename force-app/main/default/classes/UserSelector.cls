/**
 * UserSelector — the selector for User. Encapsulates ALL SOQL against User per ARCHITECTURE.md §2
 * and .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes. Nothing else
 * queries that object.").
 *
 * ── 🔴 THIS CLASS IS NOW EMPTY, AND THAT IS A DELIBERATE, TEMPORARY STATE ─────
 * It held exactly two methods — `selectDealDriverFlagForCurrentUser()` and
 * `selectDispositionDriverFlagForCurrentUser()` — and both were removed on 2026-08-12 when the
 * `User.Deal_Driver__c` / `User.Disposition_Driver__c` authorization-flag model was retired in
 * favour of Custom Permissions. Nothing in the application called them any more, and a selector
 * method with no caller is dead SOQL that a future reader will assume is load-bearing.
 *
 * ⚠ `UserSelectorTest` WAS DELETED IN THIS PHASE, NOT IN PHASE 2. Every one of its nine call sites
 * referenced the two removed methods, so once they were gone the test could not COMPILE and would
 * have blocked every deploy. Deleting it was unavoidable and is already done.
 *
 * 🔴 THAT VOIDS THE ARGUMENT THIS HEADER USED TO MAKE FOR KEEPING THE CLASS, AND THE CORRECTION
 * MATTERS. It previously claimed the fields, their grants, this class AND `UserSelectorTest` would
 * "all go together" in Phase 2, and that deleting the class now "would have removed the rollback
 * lever's test coverage a phase early". **There is no coverage left to remove** — it went with the
 * test — so coverage cannot be a reason to keep this file, and anyone re-reading the old wording
 * would be weighing a protection that no longer exists.
 *
 * ⇒ SO BE HONEST ABOUT WHAT THIS FILE IS: an empty shell with **no test coverage and no functional
 * purpose**. Its only remaining value is documentary, and it is worth more than the tidiness of
 * deleting an empty file:
 *   1. it is the MARKER for the Phase-2 deletion, so that retirement stays a single reviewable change;
 *   2. it is the only surviving control against someone re-adding an inline `User` query — see the
 *      two rules below, which exist nowhere else in the codebase.
 *
 * ── PHASE-2 DELETE LIST (what ACTUALLY remains) ───────────────────────────────
 * Following docs/permission-set-retirement-runbook.md's GRANT → VERIFY → REMOVE → SOAK → DELETE order:
 *   - `User.Deal_Driver__c` and `User.Disposition_Driver__c` (the rollback lever, still live);
 *   - their `<fieldPermissions>` grants in the two layer-5 sets, `Acquisition_Deal_Driver` and
 *     `Disposition_Deal_Driver`;
 *   - this class.
 * `UserSelectorTest` is deliberately NOT on that list — it is already gone.
 *
 * ⚠ WHEN THIS CLASS IS DELETED, RECORD THE CONSEQUENCE — IT IS LARGER THAN IT LOOKS. This was the
 * FIRST AND ONLY `User` SOQL in the application. Once the file is gone the next feature that needs to
 * read a `User` will find no selector and will be tempted to inline the query, which the layering
 * rule forbids. ARCHITECTURE.md §2 already carries this note (added 2026-08-12); keep it there when
 * the file goes, because at that point it becomes the ONLY surviving statement of it. A `User` read
 * must RE-CREATE this selector rather than inline, exactly as `AccountSelector` and
 * `OpportunityContactRoleSelector` were created as the first reads of their objects.
 *
 * ── WHY THE TWO METHODS WERE SEPARATE QUERIES, AND WHY THAT REASONING IS NOW MOOT ──
 * This is recorded rather than deleted because the reasoning was subtle, correct, and is the kind of
 * thing a future reader would otherwise "discover" and re-apply somewhere it does not belong.
 *
 * The two reads were deliberately NOT merged into a single
 * `SELECT Deal_Driver__c, Disposition_Driver__c`, even though that is tidier and costs one query
 * instead of two. `WITH USER_MODE` throws when the running user cannot read ANY selected field, so
 * an acquisitions deal driver — who holds FLS on `Deal_Driver__c` and not on
 * `Disposition_Driver__c` — would have made the merged read throw. Both calling services converted a
 * throw to `false`, so the merge would have silently DENIED a legitimate acquisitions deal driver
 * the actions they had always had. One field per query is what kept the two gates independent.
 *
 * ⇒ THE REASONING EVAPORATES WITH THE FLAGS. It depended entirely on `WITH USER_MODE` FLS enforcement
 * being HALF THE GATE — the throw WAS the denial signal for factor (a). Custom permissions have no
 * FLS, so there is no per-field denial signal to keep separable and no gate left to break by
 * merging. Do not carry this rule forward to a future `User` selector: it was a property of the flag
 * model, not a general rule about selecting two fields.
 *
 * ⚠ THE GENERAL LESSON THAT DOES SURVIVE: a `WITH USER_MODE` query throws on the WHOLE row for ONE
 * inaccessible field, so widening a selector's field list can break an existing caller that has
 * nothing to do with the new field. That is a real, transferable trap (see
 * `InboundEmailStagingSelector.selectById`, where `Routing_Attempt_Count__c` was deliberately kept
 * OUT of the read every inbound email performs, for exactly this reason).
 *
 * ── WHAT REPLACED IT ──────────────────────────────────────────────────────────
 * `OpportunityActionPermissionService` and `DispositionActionPermissionService` now call
 * `FeatureManagement.checkPermission('Acquisition_Deal_Actions' | 'Disposition_Deal_Actions')`,
 * which costs ZERO SOQL and has no FLS surface at all. Read either class's header for the measured
 * reason the flag model was retired.
 *
 * ── MODE ──────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector), retained so that re-adding a
 * method here starts from the correct default. Note the repo standard deliberately differs from the
 * generic sf-apex skill default of `inherited sharing`.
 *
 * ── ⚠ IF YOU ADD A METHOD HERE, RESTORE THE SCOPE RULE WITH IT ───────────────
 * Every method this class ever held was hard-filtered to `Id = UserInfo.getUserId()` and took no
 * user parameter. That was deliberate and is what made the class safe to reach (indirectly) from an
 * `@AuraEnabled` boundary: a user could never use it to read ANOTHER user's record and map out who
 * in the org can drive deals. `PermissionSetAssignmentSelector` makes the same design decision. A
 * new method that accepts a `Set<Id>` of users is not a bulkification improvement here — it is a
 * security decision that needs its own argument.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (former consumer)
 * @see force-app/main/default/classes/DispositionActionPermissionService.cls (former consumer)
 * @see force-app/main/default/objects/User/fields/Deal_Driver__c.field-meta.xml (delete candidate)
 * @see force-app/main/default/objects/User/fields/Disposition_Driver__c.field-meta.xml (delete candidate)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class UserSelector {
}
