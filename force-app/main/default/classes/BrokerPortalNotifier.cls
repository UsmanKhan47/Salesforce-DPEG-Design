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
        // SOQL relocated to per-object selectors (Module A2) per ARCHITECTURE.md §2.
        // All three run WITH SYSTEM_MODE: this is the guest/automation Broker-Portal
        // path (setup-object + Lead lookups). See each selector's header for the
        // SYSTEM_MODE justification.
        CustomNotificationType notifType = NotificationTypeSelector.selectByDeveloperName(NOTIF_TYPE_DEV_NAME);
        Group queue = QueueGroupSelector.selectQueueByDeveloperName(QUEUE_DEV_NAME);
        if (notifType == null || queue == null) {
            return;
        }
        Id typeId = notifType.Id;
        Set<String> recipients = new Set<String>{ queue.Id };

        for (Lead l : LeadSelector.selectByIdsSystem(new Set<Id>(leadIds))) {
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