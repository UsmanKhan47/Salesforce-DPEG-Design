/**
 * Selector for the standard EmailMessageRelation object. Encapsulates ALL SOQL
 * against EmailMessageRelation per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * NEW 2026-08-02 with the EAC Thread Guard. Sole consumer: EmailThreadGuardService.
 *
 * WHAT THIS OBJECT IS, AND WHY THE GUARD IS BUILT ON IT. EmailMessageRelation is the
 * join Einstein Activity Capture writes to record WHICH RECORDS a captured email was
 * matched to — one row per matched User / Lead / Contact. EAC matches on ADDRESS
 * ALONE and is completely thread-blind, so these rows are precisely the
 * over-association the guard exists to undo: they are the reason an unrelated
 * conversation with a broker appears on that broker's deal Lead.
 *
 * They are ALSO how the guard knows when it must NOT act: the same rows reveal that a
 * capture legitimately belongs to a Contact (or any other record) whose timeline this
 * feature has no mandate to prune. See the method Javadoc — this selector deliberately
 * returns every relation type, not just Leads.
 *
 * ── MODE — `WITH SYSTEM_MODE`, and this is a correctness requirement ──────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector); only the
 * QUERY mode differs from the repo default. The guard runs entirely in an automated
 * context (EAC insert → EmailMessageTrigger → EmailCaptureQueueable) as a
 * principal this repo's permission sets never provision. Under `WITH USER_MODE` a
 * missing FLS grant on any field below THROWS rather than degrades: the queueable
 * dies, and the guard is silently disabled while EAC keeps polluting Lead timelines.
 * SYSTEM_MODE is the only mode under which this read is reliable — the same
 * automation-path reasoning as LeadSelector.GuestReads / ContactSelector.GuestReads /
 * GroupMemberSelector / ProcessInstanceStepSelector.AuditReads.
 *
 * @see EmailThreadGuardService.cls (the only consumer, and the full feature rationale)
 * @see EmailMessageSelector.cls (sibling — the captured messages themselves)
 */
public with sharing class EmailMessageRelationSelector {

    /**
     * EVERY association EAC created for a set of captured emails — Lead, Contact, User
     * and anything else it matched. Backs both halves of EmailThreadGuardService's
     * decision: "which Leads did this land on?" AND "does this capture also live on a
     * record outside the guard's scope?".
     *
     * ⚠ THIS METHOD IS DELIBERATELY NOT LEAD-FILTERED (widened 2026-08-02, review W1).
     * It used to be `selectLeadRelationsByMessageIds` and filtered
     * `RelationObjectType = 'Lead'` in SOQL. That was a correct trigger condition but
     * the WRONG read, because the guard's remedy is not scoped the way its condition
     * was: deleting an EmailMessage removes it from Salesforce ENTIRELY, so a capture
     * EAC stapled to both a Contact and a Lead would be judged solely on the Lead and
     * vanish from the Contact's timeline too — a record the feature declares out of
     * scope. Real in this org: the same brokers exist as Contacts
     * (Broker_Assignment__c / Lease_Inquiry__c) and as Leads (Broker Protection), and
     * EAC matches by address. The service now needs to SEE the non-Lead rows in order
     * to protect them, so the Lead scoping moved OUT of this query and into explicit
     * Apex in EmailThreadGuardService — where the classification decision is
     * documented. The rename is part of the fix: a method still called
     * `selectLeadRelations...` that no longer filters to Lead is a trap.
     *
     * ⚠ THIS QUERY IS WHY THE TRIGGER MUST BE ASYNC (prompt §4 gotcha 4). EAC inserts
     * these relation rows AFTER the EmailMessage within the same transaction, so a
     * synchronous after-insert trigger reading this would legitimately find none and
     * conclude "not Lead-related" for every capture. The queueable hop is what makes
     * this read return the truth — do not "optimize" it back into the trigger.
     *
     * ONE QUERY, NOT TWO: both questions are answered from the same row set on purpose.
     * Splitting them into a Lead read plus a non-Lead read would double the query cost
     * on an EAC batch and, worse, allow the two answers to disagree.
     *
     * `RelationId != null` is retained from the verified source-org query: a relation
     * row can carry an unresolved address with no matched record, and such a row is
     * evidence of nothing — neither a Lead association nor a record to protect.
     *
     * @param messageIds EmailMessage Ids whose associations to load; null/empty-safe.
     * @return Relation rows (EmailMessageId, RelationId, RelationObjectType) for every
     *         matched object type; an empty list when the input is null/empty or the
     *         messages matched nothing (never null).
     * @example
     * List<EmailMessageRelation> rels =
     *     EmailMessageRelationSelector.selectByMessageIds(messageIds);
     */
    public static List<EmailMessageRelation> selectByMessageIds(Set<Id> messageIds) {
        if (messageIds == null || messageIds.isEmpty()) {
            return new List<EmailMessageRelation>();
        }
        return [
            SELECT EmailMessageId, RelationId, RelationObjectType
            FROM EmailMessageRelation
            WHERE EmailMessageId IN :messageIds
              AND RelationId != null
            WITH SYSTEM_MODE
        ];
    }
}
