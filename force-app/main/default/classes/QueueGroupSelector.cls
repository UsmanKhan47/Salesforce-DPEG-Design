/**
 * Selector for Group (queues) and for the queue-to-object junction QueueSobject.
 * Encapsulates ALL SOQL against both per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md.
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
 *   - OpportunityReviewService — selectQueueIdByDeveloperNameForSObject (the LOI
 *     block, resolving the Acquisition queue that OWNS every auto-created LOI).
 *
 * ⚠ QueueSobject LIVES HERE RATHER THAN IN ITS OWN SELECTOR, AND THAT IS A DECISION,
 * NOT AN OVERSIGHT. This repo otherwise gives a junction object its own selector
 * (EmailMessageRelationSelector, PermissionSetGroupComponentSelector). QueueSobject is
 * the exception because it has no independent existence: it carries no data of its own
 * beyond "this queue may own that object", i.e. it is an ATTRIBUTE OF A QUEUE, and this
 * class is named for queues rather than for the Group table. Splitting it out would put
 * two halves of one question ("does this queue exist" / "may it own this object") in two
 * files, which is how a caller ends up asking only the first — the exact defect
 * selectQueueIdByDeveloperNameForSObject exists to prevent.
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

    /**
     * The Id of the queue that is ENABLED TO OWN `sobjectType`, matched by the queue's
     * DeveloperName — or null when no such queue exists, is not enabled for that object, or
     * either input is blank.
     *
     * 🔴 THIS IS A STRICTLY NARROWER QUESTION THAN selectQueueByDeveloperName's, AND IT IS THE
     * ONLY ONE AN `OwnerId` ASSIGNMENT MAY BE BUILT ON. A queue that exists but does not list
     * the object in its `queueSobject` set CANNOT own a record of that type: the platform
     * refuses the DML, and on an after-update trigger path that refusal does not cost the child
     * record — it rolls back the whole transaction that triggered it. Resolving the queue by
     * DeveloperName ALONE therefore answers a question whose "yes" still does not license the
     * write. Asking QueueSobject answers both halves in ONE query, which is why the caller gets
     * an Id back rather than a Group.
     *
     * MODE — `WITH SYSTEM_MODE` for the reason stated in the class header: Group and
     * QueueSobject are setup objects with no meaningful FLS story, every caller is an
     * automation path, and USER_MODE throws rather than degrades. A throw here is precisely
     * what OpportunityReviewService's LOI block must never experience.
     *
     * NOT-FOUND CONTRACT — null, never an exception. The caller decides what "no queue" means;
     * for the LOI block it means "keep the pre-existing owner".
     *
     * @param developerName Group.DeveloperName of the queue to match; null/blank-safe.
     * @param sobjectType   API name of the object the queue must be enabled for
     *                      (e.g. 'LOI__c'); null/blank-safe.
     * @return The queue's Group Id, or null.
     * @example
     * Id q = QueueGroupSelector.selectQueueIdByDeveloperNameForSObject('Acquisition', 'LOI__c');
     */
    public static Id selectQueueIdByDeveloperNameForSObject(String developerName, String sobjectType) {
        if (String.isBlank(developerName) || String.isBlank(sobjectType)) {
            return null;
        }
        List<QueueSobject> enabled = [
            SELECT QueueId
            FROM QueueSobject
            WHERE SobjectType = :sobjectType AND Queue.DeveloperName = :developerName
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return enabled.isEmpty() ? null : enabled[0].QueueId;
    }
}
