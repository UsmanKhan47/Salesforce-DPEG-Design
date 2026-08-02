/**
 * Selector for the standard EmailMessage object. Encapsulates ALL SOQL against
 * EmailMessage per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * NEW 2026-08-02 with the EAC Thread Guard — no EmailMessage selector previously
 * existed anywhere in this repo, because until Einstein Activity Capture was
 * enabled this org never materialized an EmailMessage. Consumers:
 * EmailThreadAnchorService (building the shared index), EmailThreadAdopterService
 * and EmailThreadGuardService.
 *
 * ── MODE — `WITH SYSTEM_MODE`, and this is a correctness requirement ──────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector); only the
 * QUERY mode differs from the repo default, and deliberately so.
 *
 * The feature's entire execution context is automated: an EAC capture inserts the
 * EmailMessage, EmailMessageTrigger enqueues EmailCaptureQueueable, and the
 * queueable runs as whichever principal EAC committed under (the connected-mailbox
 * user, or Automated Process). That principal is NOT provisioned with this repo's
 * permission sets and has no guaranteed FLS on the fields below. Under
 * `WITH USER_MODE` an inaccessible field does not degrade — the query THROWS, the
 * queueable dies, and the guard is silently disabled while EAC keeps polluting Lead
 * timelines with no error anyone would see. SYSTEM_MODE is therefore the only mode
 * under which this read is reliable.
 *
 * The exposure is nil: the fields are RFC routing identifiers plus an activity
 * pointer on rows the platform created seconds earlier, read solely to decide
 * whether the platform's own over-association should be undone. No business data
 * crosses this boundary and nothing is returned to a user. This follows the
 * established repo precedent for automation-path reads —
 * LeadSelector.GuestReads / ContactSelector.GuestReads / GroupMemberSelector /
 * ProcessInstanceStepSelector.AuditReads.
 *
 * @see EmailThreadGuardService.cls (the full feature rationale)
 * @see EmailThreadAdopterService.cls (the mirror half — RelatedToId is its write target)
 * @see EmailMessageRelationSelector.cls (sibling — which Leads a message landed on)
 * @see force-app/main/default/classes/GroupMemberSelector.cls (SYSTEM_MODE precedent)
 */
public with sharing class EmailMessageSelector {

    /**
     * EAC-captured (or composer-logged) emails by Id, carrying everything the thread
     * guard needs to make its keep/delete decision:
     *
     *   • ThreadIdentifier  — the RFC Message-ID of the THREAD ROOT. For a reply this
     *     is the original message's ID, which is exactly what the pipeline stamped on
     *     its anchor Task as Thread_Key__c. This is the primary match key.
     *   • MessageIdentifier — the email's OWN Message-ID. Matched as a secondary key
     *     because a thread root's ThreadIdentifier IS its own MessageIdentifier, and
     *     the pipeline anchors that root under Inbound_Message_Id__c.
     *   • ActivityId        — the companion Task the platform auto-creates for the
     *     message. Two jobs: it is the EAC fingerprint carrier (its CreatedBy.UserType)
     *     and the ONLY handle the guard has on a deletable Task.
     *   • RelatedToId       — the record EAC associated the capture with (added 2026-08-02).
     *     BOTH features need it: it is the adopter's write target and its contention input
     *     (D4), and it is the guard's widened guard-4 input — a capture anchored on its
     *     RelatedToId record must be KEPT even when no related Lead anchors it. Before this
     *     field was selected the guard could not see it at all, so it deleted adopted
     *     captures seconds after the adopter wrote them (finding P6).
     *
     * ⚠ DO NOT NARROW THIS FIELD SET. Dropping ActivityId silently converts the guard
     * into a no-op that can never identify an EAC-materialized message; dropping either
     * identifier makes every capture look unanchored; dropping RelatedToId reopens P6.
     *
     * @param messageIds EmailMessage Ids to load; null/empty-safe.
     * @return Matching EmailMessages with Id, ThreadIdentifier, MessageIdentifier and
     *         ActivityId populated; an empty list when the input is null/empty or the
     *         rows are already gone (never null).
     * @example
     * List<EmailMessage> msgs = EmailMessageSelector.selectByIds(messageIds);
     */
    public static List<EmailMessage> selectByIds(Set<Id> messageIds) {
        if (messageIds == null || messageIds.isEmpty()) {
            return new List<EmailMessage>();
        }
        return [
            SELECT Id, ThreadIdentifier, MessageIdentifier, ActivityId, RelatedToId
            FROM EmailMessage
            WHERE Id IN :messageIds
            WITH SYSTEM_MODE
        ];
    }
}
