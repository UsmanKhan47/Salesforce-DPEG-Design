/**
 * Selector for GroupMember. Encapsulates ALL SOQL against GroupMember per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live
 * in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave (Group + guest-notifier cluster). NEW selector — no GroupMember
 * selector previously existed anywhere. Consumer: GroupNotifier (the generic
 * acquisition deal-lifecycle in-app notifier), which resolves the user members of a
 * public group / queue to build the custom-notification recipient set.
 *
 * ── MODE ──────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector).
 *
 * The read uses `WITH SYSTEM_MODE` (API 67), justified: GroupNotifier is an
 * automation/guest-path notifier (it is `without sharing`, callable from Flow and
 * from Apex services). GroupMember is a SETUP object — it has no field-level
 * security and no sharing model to enforce, so `WITH USER_MODE` would be inert on
 * the FLS axis and would only risk over-restricting record visibility on a setup
 * lookup that must resolve group membership deterministically. Per the P4 design §5
 * the guest/automation path is explicitly SYSTEM_MODE and is not placed under
 * USER_MODE unverified (guest FLS lives on the non-deployable Guest Profile; P3's
 * guest spike never completed). This is a GroupId -> member-Id resolution of group
 * membership, not user record data.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/QueueGroupSelector.cls (sibling setup-object selector)
 * @see agent-output/p4-selector-design.md (§2, §5)
 */
public with sharing class GroupMemberSelector {

    /**
     * The GroupMember rows for a set of groups — backs GroupNotifier's resolution of
     * a group's / queue's direct members. Bulk-safe: one query for the whole set of
     * group Ids (never per-group).
     *
     * @param groupIds Group Ids whose members to load; null/empty-safe.
     * @return GroupMembers with GroupId and UserOrGroupId populated (the caller
     *         filters UserOrGroupId to user members by key prefix); an empty list
     *         when the input is null or empty (never null).
     * @example
     * List<GroupMember> members = GroupMemberSelector.selectByGroupIds(groupIds);
     */
    public static List<GroupMember> selectByGroupIds(Set<Id> groupIds) {
        if (groupIds == null || groupIds.isEmpty()) {
            return new List<GroupMember>();
        }
        return [
            SELECT GroupId, UserOrGroupId
            FROM GroupMember
            WHERE GroupId IN :groupIds
            WITH SYSTEM_MODE
        ];
    }
}
