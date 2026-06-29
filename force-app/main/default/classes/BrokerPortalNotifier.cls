public without sharing class BrokerPortalNotifier {

    private static final String NOTIF_TYPE_DEV_NAME = 'Broker_Portal_New_Lead';
    private static final String QUEUE_DEV_NAME = 'Broker_Portal_Leads';

    @InvocableMethod(
        label='Notify Broker Portal New Leads'
        description='Sends an in-app custom notification to the Broker Portal Leads queue for new broker submissions.'
    )
    public static void notifyNewLeads(List<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return;
        }
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIF_TYPE_DEV_NAME LIMIT 1
        ];
        List<Group> queues = [
            SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :QUEUE_DEV_NAME LIMIT 1
        ];
        if (types.isEmpty() || queues.isEmpty()) {
            return;
        }
        Id typeId = types[0].Id;
        Set<String> recipients = new Set<String>{ queues[0].Id };

        for (Lead l : [SELECT Id, Name, Company, Property_Address__c FROM Lead WHERE Id IN :leadIds]) {
            String addr = String.isBlank(l.Property_Address__c) ? l.Name : l.Property_Address__c;
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(typeId);
            n.setTargetId(l.Id);
            n.setTitle('New broker deal submitted');
            n.setBody(l.Company + ' - ' + addr);
            try {
                n.send(recipients);
            } catch (Exception e) {
                // A notification failure must never roll back the lead transaction.
                System.debug(LoggingLevel.WARN, 'Broker portal notification failed: ' + e.getMessage());
            }
        }
    }
}