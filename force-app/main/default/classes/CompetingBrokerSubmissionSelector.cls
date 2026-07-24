/**
 * Selector for Competing_Broker_Submission__c. Encapsulates ALL SOQL against
 * Competing_Broker_Submission__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * Broker Protection module (CHUNK 1). Competing_Broker_Submission__c is the
 * append-only log of every broker who submitted the same property: the first
 * becomes the Winning_Lead__c (Is_Winning_Submission__c = true) and later brokers
 * are recorded as competing submissions against that same winner. Consumers land in
 * CHUNK 2/3.
 *
 * MODE — the single query uses `WITH USER_MODE` (API 67). Competing_Broker_Submission__c
 * is a custom object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe
 * and enforces the running user's sharing + FLS. No guest path — no SYSTEM_MODE here.
 *
 * SIGNATURE CONTRACT — the public method is STATIC, matching the repo selector norm
 * (BovSubmissionSelector, CounterOfferSelector, ContactSelector, LeadSelector all
 * expose `public static` query methods). It keeps the exact signature the
 * Broker-Protection chunk plan fixed; CHUNK 2/3 bind to it by name
 * (`CompetingBrokerSubmissionSelector.selectByWinningLead(...)`). Do not rename or
 * change its parameter/return type.
 *
 * NOT-FOUND CONTRACT — read-for-display: a winning lead with no competing
 * submissions is normal, so this returns its natural empty List, never null.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see PropertyRegistrySelector.cls (sibling Broker-Protection selector)
 */
public with sharing class CompetingBrokerSubmissionSelector {

    /**
     * All submissions tied to one winning lead, oldest first — backs the
     * competing-broker timeline for a claimed property. ORDER BY
     * Submitted_DateTime__c ASC puts the earliest (winning) submission at the top so
     * the timeline reads in chronological order.
     *
     * @param leadId Winning_Lead__c Id whose submissions to read; null returns an
     *               empty list.
     * @return Competing_Broker_Submission__c rows (Id, Broker_Name__c,
     *         Broker_Email__c, Forwarded_By_Email__c, Property_Address_Raw__c,
     *         Submitted_DateTime__c, Is_Winning_Submission__c) for that winning lead,
     *         ordered by Submitted_DateTime__c ASC; empty when `leadId` is null or
     *         there are none.
     * @example
     * List<Competing_Broker_Submission__c> subs =
     *     CompetingBrokerSubmissionSelector.selectByWinningLead(leadId);
     */
    public static List<Competing_Broker_Submission__c> selectByWinningLead(Id leadId) {
        if (leadId == null) {
            return new List<Competing_Broker_Submission__c>();
        }
        return [
            SELECT Id, Broker_Name__c, Broker_Email__c, Forwarded_By_Email__c,
                   Property_Address_Raw__c, Submitted_DateTime__c,
                   Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :leadId
            WITH USER_MODE
            ORDER BY Submitted_DateTime__c ASC
        ];
    }
}
