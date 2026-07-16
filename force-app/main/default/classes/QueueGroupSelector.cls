/**
 * Selector for Group (queues). Encapsulates ALL SOQL against Group per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A2 (Acquisitions — Deal Support). Consumer: BrokerPortalNotifier
 * (the guest/automation Broker-Portal lead-intake notification path). The later
 * cleanup wave will also point BrokerPortalController here (out of scope now).
 *
 * MODE — `WITH SYSTEM_MODE` (API 67), justified: invoked from BrokerPortalNotifier
 * in the guest/automation context of the public Broker Portal. Group is a setup
 * object with no guest FLS, and guest FLS lives on the non-deployable Guest
 * Profile (P3's guest FLS spike never completed). Per the P4 design §5 the guest
 * path is NOT placed under USER_MODE unverified. This is a DeveloperName -> Id
 * lookup of a queue, not user record data.
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
}
