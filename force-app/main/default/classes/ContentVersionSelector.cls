/**
 * Selector for the standard ContentVersion object. Encapsulates ALL SOQL against
 * ContentVersion per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * NEW 2026-08-05 with inbound broker-email attachment capture. This is the FIRST
 * ContentVersion SOQL in the application — there was none before it, exactly as
 * AccountSelector (2026-08-02) and OpportunityContactRoleSelector (2026-08-03) were
 * first of their kind. Every future ContentVersion read belongs here.
 *
 * WHY THE READ EXISTS AT ALL. An inserted ContentVersion sObject does NOT carry
 * ContentDocumentId back on the in-memory row — the platform creates the owning
 * ContentDocument as a side effect of the insert and populates the pointer only in the
 * database. A ContentDocumentLink needs that ContentDocumentId, so the one and only way
 * to link a file the same transaction created is to re-read it. Exactly ONE query per
 * inbound email, for the whole file set, never per file.
 *
 * ── MODE — `WITH SYSTEM_MODE`, and this is a correctness requirement ──────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector); only the QUERY
 * mode differs from the repo default, and deliberately so. SYSTEM_MODE lifts FLS and
 * CRUD ONLY — it does NOT bypass sharing, which the class declaration still governs.
 *
 * ⚠ **THE VENUE CHANGED ON 2026-08-06; THE MODE DECISION STANDS, FOR A DIFFERENT REASON.**
 * This justification used to read "a throw here destroys a valid broker email", because
 * InboundEmailAttachmentService.persist was invoked SYNCHRONOUSLY from the Email Service
 * boundary. **That is no longer true.** persist now runs only from AttachmentPersistQueueable
 * and AttachmentCarrierSweepBatch — transactions that own nothing irreplaceable — so a throw
 * here costs a DEFERRED file and nothing else: the bytes stay on the staging row as a classic
 * Attachment and the daily sweep retries them. Do not cite the old sentence.
 *
 * SYSTEM_MODE is nevertheless RETAINED, on the ordinary automation-path grounds of
 * ARCHITECTURE.md §2. The job runs as whichever principal the chain executes under — a persona
 * on `Minimum Access - Salesforce`, provisioned by permission set rather than by profile — and
 * `WITH USER_MODE` THROWS rather than degrades the instant one selected field is inaccessible
 * to it. That would SILENTLY DISABLE FILE CONVERSION org-wide: every email would keep routing
 * correctly while every file quietly failed, forever, with the only signal a failed
 * AsyncApexJob nobody is watching. Same reasoning as the EAC capture pipeline
 * (EmailMessageSelector / EmailMessageRelationSelector), LeadSelector.GuestReads and the
 * sibling AttachmentSelector.
 *
 * The exposure is nil: two system fields on rows this transaction created microseconds
 * earlier, read solely to resolve the document Id needed to link them.
 *
 * @see InboundEmailAttachmentService.cls (the only consumer)
 * @see AttachmentSelector.cls (the sibling automation-path reads on the same job)
 * @see EmailMessageSelector.cls (SYSTEM_MODE automation-path precedent)
 * @see agent-output/design-requirements-attachment-persistence-v2.md §11.12
 */
public with sharing class ContentVersionSelector {

    /**
     * Resolve the owning ContentDocument of each ContentVersion this transaction just
     * inserted. Bulk by construction — one query for the whole retained file set of one
     * inbound email; it must never be called inside a loop.
     *
     * @param ids ContentVersion Ids to resolve; null or empty short-circuits.
     * @return Matching rows (Id, ContentDocumentId); an empty list when `ids` is null or
     *         empty, or nothing matched (never null).
     * @example
     * for (ContentVersion cv : ContentVersionSelector.selectByIds(savedVersionIds)) {
     *     documentIds.add(cv.ContentDocumentId);
     * }
     */
    public static List<ContentVersion> selectByIds(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) {
            return new List<ContentVersion>();
        }
        return [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :ids
            WITH SYSTEM_MODE
        ];
    }
}
