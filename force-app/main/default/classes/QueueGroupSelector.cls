/**
 * Selector for Group (queues). Encapsulates ALL SOQL against Group per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A2 (Acquisitions — Deal Support) + P4 cleanup wave (Group +
 * guest-notifier cluster). This is the single owner of ALL SOQL against Group.
 * Consumers:
 *   - BrokerPortalNotifier — selectQueueByDeveloperName (guest/automation
 *     Broker-Portal lead-intake notification path).
 *   - BrokerPortalController — selectQueueByDeveloperName (guest LWR deal-intake
 *     controller, resolving the routing queue owner).
 *   - GroupNotifier — selectRegularAndQueueByDeveloperNames (the generic
 *     acquisition deal-lifecycle notifier, which resolves BOTH regular groups and
 *     queues in bulk, not queues alone).
 *
 * MODE — every method uses `WITH SYSTEM_MODE` (API 67), justified: all callers run
 * in a guest/automation context. Group is a setup object with no guest FLS, and
 * guest FLS lives on the non-deployable Guest Profile (P3's guest FLS spike never
 * completed). Per the P4 design §5 the guest path is NOT placed under USER_MODE
 * unverified. These are DeveloperName -> Id lookups of groups/queues, not user
 * record data.
 *
 * NOT-FOUND CONTRACT — a missing queue is a "not configured" state the caller
 * already treats as "skip notification". Returns SObject-or-null (never throws).
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #24, §4 Skeleton C, §5)
 */
public with sharing class QueueGroupSelector {

    /**
     * The queue Group matching a DeveloperName — backs BrokerPortalNotifier's
     * lookup of the "Broker_Portal_Leads" queue (the notification recipient).
     *
     * @param developerName Group.DeveloperName to match; null-safe.
     * @return The matching queue Group (Id populated), or null when the input is
     *         blank or no queue exists with that DeveloperName.
     */
    public static Group selectQueueByDeveloperName(String developerName) {
        if (String.isBlank(developerName)) {
            return null;
        }
        List<Group> queues = [
            SELECT Id
            FROM Group
            WHERE Type = 'Queue' AND DeveloperName = :developerName
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return queues.isEmpty() ? null : queues[0];
    }

    /**
     * Regular groups AND queues matching a set of DeveloperNames — backs
     * GroupNotifier, which sends a custom notification to the user members of a
     * public group OR queue (Type IN ('Regular','Queue')), so it needs a BROADER
     * filter than selectQueueByDeveloperName's Queue-only lookup. Bulk-safe: one
     * query for the whole set of names (never per-name).
     *
     * `Type IN ('Regular','Queue')` uses hardcoded literals only; `developerNames`
     * is bound — injection-safe.
     *
     * @param developerNames Group.DeveloperName values to match; null/empty-safe.
     * @return Matching Groups with Id and DeveloperName populated; an empty list
     *         when the input is null or empty (never null).
     * @example
     * for (Group g : QueueGroupSelector.selectRegularAndQueueByDeveloperNames(names)) { ... }
     */
    public static List<Group> selectRegularAndQueueByDeveloperNames(Set<String> developerNames) {
        if (developerNames == null || developerNames.isEmpty()) {
            return new List<Group>();
        }
        return [
            SELECT Id, DeveloperName
            FROM Group
            WHERE DeveloperName IN :developerNames AND Type IN ('Regular', 'Queue')
            WITH SYSTEM_MODE
        ];
    }
}
