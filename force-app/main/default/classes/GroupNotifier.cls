/**
 * Generic in-app notifier for the acquisition deal lifecycle. Sends a custom
 * notification (type: Acquisitions_Deal_Update) to every user member of a public
 * group or queue, identified by DeveloperName. Callable from flows (invocable)
 * and directly from Apex services.
 *
 * Groups are kept flat by convention (no nested groups); user members are
 * resolved one level deep. A notification failure must never roll back the
 * calling transaction, so every failure path degrades to a debug warning.
 */
public without sharing class GroupNotifier {

    private static final String NOTIF_TYPE_DEV_NAME = 'Acquisitions_Deal_Update';
    private static final String USER_KEY_PREFIX = '005';

    // Test hook: custom notifications cannot be queried in Apex tests, so tests
    // assert against the number of successful sends instead.
    @TestVisible private static Integer sentCount = 0;

    public class Request {
        @InvocableVariable(label='Group or Queue DeveloperName' required=true)
        public String recipientGroup;
        @InvocableVariable(label='Title' required=true)
        public String title;
        @InvocableVariable(label='Body' required=true)
        public String body;
        @InvocableVariable(label='Target Record Id' required=true)
        public Id targetRecordId;
    }

    /** Direct entry point for Apex callers. */
    public static void send(String groupDevName, String title, String body, Id targetId) {
        Request r = new Request();
        r.recipientGroup = groupDevName;
        r.title = title;
        r.body = body;
        r.targetRecordId = targetId;
        notify(new List<Request>{ r });
    }

    @InvocableMethod(
        label='Notify Group or Queue'
        description='Sends an Acquisitions Deal Update custom notification to all members of a public group or queue.'
    )
    public static void notify(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIF_TYPE_DEV_NAME LIMIT 1
        ];
        if (types.isEmpty()) {
            System.debug(LoggingLevel.WARN, 'GroupNotifier: notification type missing: ' + NOTIF_TYPE_DEV_NAME);
            return;
        }

        Set<String> groupNames = new Set<String>();
        for (Request r : requests) {
            if (r != null && String.isNotBlank(r.recipientGroup)) {
                groupNames.add(r.recipientGroup);
            }
        }
        Map<String, Set<String>> recipientsByGroup = resolveRecipients(groupNames);

        for (Request r : requests) {
            if (r == null || String.isBlank(r.recipientGroup) || r.targetRecordId == null) {
                continue;
            }
            Set<String> recipients = recipientsByGroup.get(r.recipientGroup);
            if (recipients == null || recipients.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'GroupNotifier: no recipients for group ' + r.recipientGroup);
                continue;
            }
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(types[0].Id);
            n.setTargetId(r.targetRecordId);
            n.setTitle(r.title);
            n.setBody(r.body);
            try {
                n.send(recipients);
                sentCount++;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'GroupNotifier: send failed for ' + r.recipientGroup + ': ' + e.getMessage());
            }
        }
    }

    /**
     * Maps each group DeveloperName to its recipient Ids: direct user members,
     * falling back to the group Id itself when the group has no user members
     * (queues accept their own Id as a notification recipient).
     */
    private static Map<String, Set<String>> resolveRecipients(Set<String> groupNames) {
        Map<String, Set<String>> result = new Map<String, Set<String>>();
        if (groupNames.isEmpty()) {
            return result;
        }
        Map<Id, String> groupIdToName = new Map<Id, String>();
        for (Group g : [
            SELECT Id, DeveloperName FROM Group
            WHERE DeveloperName IN :groupNames AND Type IN ('Regular', 'Queue')
        ]) {
            groupIdToName.put(g.Id, g.DeveloperName);
            result.put(g.DeveloperName, new Set<String>());
        }
        for (GroupMember gm : [
            SELECT GroupId, UserOrGroupId FROM GroupMember WHERE GroupId IN :groupIdToName.keySet()
        ]) {
            if (String.valueOf(gm.UserOrGroupId).startsWith(USER_KEY_PREFIX)) {
                result.get(groupIdToName.get(gm.GroupId)).add(gm.UserOrGroupId);
            }
        }
        // Empty group: fall back to the group Id (proven to work for queues).
        for (Id gId : groupIdToName.keySet()) {
            String name = groupIdToName.get(gId);
            if (result.get(name).isEmpty()) {
                result.get(name).add(gId);
            }
        }
        return result;
    }
}
