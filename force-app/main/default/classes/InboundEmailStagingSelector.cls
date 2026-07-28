/**
 * Selector for Inbound_Email_Staging__c. Encapsulates ALL SOQL against
 * Inbound_Email_Staging__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * Broker Protection module — staging model. Inbound_Email_Staging__c is the DURABLE
 * landing record for every inbound broker email: EmailToLeadHandler writes it
 * synchronously (so the email content and its RFC headers survive even if every later
 * step fails), and ExtractAddressQueueable reads it back asynchronously to run the
 * routing tree. It is the pipeline's audit trail and its restart point.
 *
 * MODE — `WITH USER_MODE` (API 67), matching every other Broker-Protection selector
 * (PropertyRegistrySelector, PropertyClaimLockSelector, CompetingBrokerSubmissionSelector).
 * The Email Service runs Apex as its configured context user, which must hold the
 * Broker_Protection_Access permission set; that permission set needs Inbound_Email_Staging__c
 * object + field permissions added for this read to succeed (see the deploy note in the
 * feature docs). There is no guest path here, so no SYSTEM_MODE appears.
 *
 * FIELD SET — deliberately WIDE: the queueable consumes almost the whole record
 * (body, subject, envelope addresses, all three RFC threading headers, the resolved
 * monitored inbox). Narrowing it would raise System.SObjectException on the first
 * unselected field read, so add to this list rather than trimming it.
 *
 * NOT-FOUND CONTRACT — returns null, not an exception. A staging record can legitimately
 * be missing by the time the async job runs (hard-deleted during an admin cleanup), and
 * the queueable handles that by logging and returning rather than crashing the job.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see InboundEmailStagingService.cls (the write side)
 */
public with sharing class InboundEmailStagingSelector {

    /**
     * The single staging record for one inbound email, with every field the routing tree
     * reads. Backs ExtractAddressQueueable's first step (load the payload it was enqueued
     * for) via InboundEmailStagingService.getStaging.
     *
     * @param stagingId Inbound_Email_Staging__c Id to load; null returns null.
     * @return The staging record, or null when `stagingId` is null or no row matches.
     * @example
     * Inbound_Email_Staging__c staging = InboundEmailStagingSelector.selectById(stagingId);
     */
    public static Inbound_Email_Staging__c selectById(Id stagingId) {
        if (stagingId == null) {
            return null;
        }
        List<Inbound_Email_Staging__c> rows = [
            SELECT Id, Name, Raw_Body__c, Raw_Headers__c, Subject__c,
                   From_Address__c, From_Name__c, Forwarded_By__c,
                   Message_Id__c, In_Reply_To__c, References__c,
                   Has_Image__c, Image_Mime_Type__c,
                   Status__c, Outcome__c, Result_Record_Id__c, Processed_DateTime__c, Error__c
            FROM Inbound_Email_Staging__c
            WHERE Id = :stagingId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }
}
