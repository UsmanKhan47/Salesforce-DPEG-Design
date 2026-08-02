/**
 * Selector for User. Encapsulates ALL SOQL against User per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes. Nothing else
 * queries that object.").
 *
 * Consumer: OpportunityActionPermissionService — the permission gate behind the Opportunity stage
 * quick actions (Begin Review, Send to Development / Construction Review, Initiate Underwriting,
 * Initiate LOI, Advance to PSA, Move to About to Close, Close Deal, Submit for Approval). It
 * answers "is the RUNNING user flagged as a deal driver?".
 *
 * ── SCOPE: THE RUNNING USER ONLY ──────────────────────────────────────────────
 * Every method here is hard-filtered to `Id = UserInfo.getUserId()` and takes no user parameter.
 * That is deliberate and is what makes the class safe to reach (indirectly) from an `@AuraEnabled`
 * boundary: a user can never use it to read ANOTHER user's Deal_Driver__c flag and so map out who
 * in the org can drive deals. Mirrors the same design decision in
 * PermissionSetAssignmentSelector.
 *
 * ── WHY `WITH USER_MODE` IS LOAD-BEARING HERE, NOT JUST COMPLIANCE ────────────
 * For most selectors USER_MODE is a guardrail. Here it is HALF THE GATE. The Opportunity actions
 * are protected by a TWO-FACTOR condition — the running user must (a) have FLS read on
 * `User.Deal_Driver__c`, granted only by the `Acquisition_Deal_Driver` permission set, AND (b) have
 * that checkbox set to true on their own User record. `WITH USER_MODE` is what enforces factor (a):
 * for a user without that FLS the query THROWS (`System.QueryException`, surfacing as "No such
 * column 'Deal_Driver__c' on entity 'User'") rather than returning the row with a null field.
 *
 * That throw is not a fault — it is the denial signal, and the calling service converts it to
 * `false` (fail closed). Removing `WITH USER_MODE`, or "fixing" the exception by widening FLS,
 * would silently reduce the gate to a single factor and grant the actions to every user whose flag
 * happened to be true. Do not weaken it.
 *
 * ⚠ FLS truth lives in the ORG, not in this repo — profiles are `.forceignore`d (ARCHITECTURE.md
 * §1 / the Opportunity design doc). Never validate this behaviour as an administrator: "Modify All
 * Data" bypasses the gate entirely in the service above.
 *
 * ── MODE ──────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector). Note that the repo standard
 * deliberately differs from the generic sf-apex skill default of `inherited sharing`; every
 * existing selector in this codebase uses `with sharing` and ARCHITECTURE.md wins.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply: this selector performs
 * ONE query for ONE user (the running user) per transaction, with no loop and no per-record work.
 * It is the same per-transaction-singleton shape the rule already exempts, and there is no
 * collection-shaped behaviour at this layer to bulk-test. No `Set<Id>` overload is offered — see
 * SCOPE above; adding one would be a security regression, not a bulkification improvement.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (sole consumer)
 * @see force-app/main/default/objects/User/fields/Deal_Driver__c.field-meta.xml
 * @see force-app/main/default/permissionsets/Acquisition_Deal_Driver.permissionset-meta.xml
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class UserSelector {

    /**
     * The running user's deal-driver flag.
     *
     * NOT-FOUND CONTRACT — returns `null` rather than throwing when no row comes back. In practice
     * that cannot happen (a running user always has a User record), but the caller treats `null` as
     * DENIED, so the contract keeps the gate failing closed even in an impossible state instead of
     * NPE-ing on an unchecked single-row assignment.
     *
     * @return the running user with Id and Deal_Driver__c populated; `null` if no row matched.
     * @throws System.QueryException when the running user lacks FLS read on `User.Deal_Driver__c`.
     *         This is EXPECTED for an unprivileged user and is the gate's first factor — see the
     *         class header. Callers must treat it as a denial, never as a system fault to retry.
     * @example
     * User runningUser = UserSelector.selectDealDriverFlagForCurrentUser();
     * Boolean isDealDriver = runningUser != null && runningUser.Deal_Driver__c == true;
     */
    public static User selectDealDriverFlagForCurrentUser() {
        Id runningUserId = UserInfo.getUserId();
        List<User> rows = [
            SELECT Id,
                   Deal_Driver__c
            FROM User
            WHERE Id = :runningUserId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }
}
