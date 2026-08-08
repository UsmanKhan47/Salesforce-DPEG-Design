/**
 * Selector for the standard classic `Attachment` object. Encapsulates ALL SOQL against
 * Attachment per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * NEW 2026-08-06 with the inbound broker-email attachment-persistence REDESIGN (v2). This is
 * the FIRST Attachment SOQL in the application — there was none before it, exactly as
 * AccountSelector (2026-08-02), OpportunityContactRoleSelector (2026-08-03) and
 * ContentVersionSelector (2026-08-05) were first of their kind. Every future Attachment read
 * belongs here.
 *
 * ═══ WHY A CLASSIC `Attachment` EXISTS IN THIS PIPELINE AT ALL ═══
 * It is a temporary BYTE CARRIER, not storage. The bytes of a broker's attachment exist only
 * inside `Messaging.InboundEmail`, in the synchronous handler, and must survive into a later
 * transaction where a `ContentVersion` insert is safe to attempt. A classic Attachment does
 * that at ZERO ContentPublication cost (spike SP-4.1, definitive) and ~152 bytes of
 * synchronous heap regardless of file size (SP-4.3, measured identically at 3 MB and 5 MB —
 * `Body = <blob>` on a fresh row is a reference assignment, not a copy). Crucially, if every
 * downstream step fails, THE BYTES ARE STILL THERE. No other carrier has that property.
 *
 * ═══ 🔴 THE TWO-METHOD SPLIT IS LOAD-BEARING. NEVER MERGE THEM. ═══
 * `selectMetadataByParentIds` deliberately does NOT select `Body`, and
 * `selectBodiesByIds` deliberately does. That split is the entire mechanism behind the
 * conversion heap gate (design §6.2):
 *
 *   • `BodyLength` is queryable WITHOUT allocating a single byte of the file.
 *   • So `AttachmentPersistQueueable` reads metadata first, decides which subset fits
 *     `InboundEmailAttachmentService.CONVERT_MAX_TOTAL_BYTES`, and only THEN issues a second
 *     query for the bodies of exactly that subset.
 *   • The gate therefore operates on the real byte counts BEFORE a single byte enters heap.
 *     It is a PRE-CHECK, not a hope.
 *
 * SP-4.5 measured why this matters: converting ONE 5 MB Attachment peaked at 10,487,036 bytes
 * of the 12,000,000-byte async heap ceiling (87%), because the SOQL read allocates the full
 * body and `VersionData = att.Body` allocates it AGAIN — peak ≈ 2 × BodyLength. Anyone who
 * merges these two methods into a single "select everything including Body" re-opens that risk
 * and turns the pre-check into a post-mortem. Two SOQL instead of one is the price and it is
 * worth it.
 *
 * ── MODE — `WITH SYSTEM_MODE`, justified at each declaration ─────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector); only the QUERY mode
 * differs from the repo default. SYSTEM_MODE lifts FLS and CRUD ONLY — it does NOT bypass
 * sharing, which the class declaration still governs, so these reads return exactly the rows
 * the running principal could already see.
 *
 * This is an automation-path read in the ARCHITECTURE.md §2 sense: nobody ASKED for it. The
 * callers are `AttachmentPersistQueueable` (chained from the routing job, running as whichever
 * principal the chain executes under — a persona on `Minimum Access - Salesforce`) and
 * `AttachmentCarrierSweepBatch` (a scheduled job). `WITH USER_MODE` THROWS rather than degrades
 * the instant one selected field is inaccessible to that principal, which would silently
 * disable file conversion AND the retry sweep while carriers accumulated on staging rows.
 * Same reasoning as `TaskSelector`'s EAC/rollup reads and `LeadSelector.GuestReads`.
 *
 * @see AttachmentPersistQueueable.cls (the heap gate that this split exists to serve)
 * @see InboundEmailAttachmentService.cls (stageBytes writes these rows; persist converts them)
 * @see agent-output/design-requirements-attachment-persistence-v2.md §6.2, §11.1
 * @see agent-output/spike-attachment-persistence-v2.md (SP-4, the measured platform facts)
 */
public with sharing class AttachmentSelector {

    /**
     * Carrier METADATA for the given parent records — 🔴 **NO `Body`. NEVER ADD `Body` HERE.**
     *
     * Selecting `Body` allocates BodyLength bytes of heap PER ROW, and the whole point of this
     * method is to let the caller decide WHICH rows it can afford before that happens. A future
     * editor who "simplifies" this by adding `Body` (or by merging this method with
     * `selectBodiesByIds`) removes the conversion heap gate's only mechanism — see the class
     * header for SP-4.5's 10.49 MB measurement.
     *
     * `ORDER BY BodyLength ASC` makes deferral DETERMINISTIC: small files convert first, so one
     * oversized carrier can never starve three small ones, and a partially-converted staging row
     * converges over successive sweeper passes instead of oscillating.
     *
     * @param parentIds The parent record Ids (Inbound_Email_Staging__c rows); null or empty
     *                  short-circuits without a query.
     * @return Matching rows (Id, Name, ContentType, BodyLength, ParentId) smallest-first; an
     *         empty list when `parentIds` is null/empty or nothing matched (never null).
     * @example
     * List<Attachment> carriers =
     *     AttachmentSelector.selectMetadataByParentIds(new Set<Id>{ stagingId });
     */
    public static List<Attachment> selectMetadataByParentIds(Set<Id> parentIds) {
        if (parentIds == null || parentIds.isEmpty()) {
            return new List<Attachment>();
        }
        return [
            SELECT Id, Name, ContentType, BodyLength, ParentId
            FROM Attachment
            WHERE ParentId IN :parentIds
            WITH SYSTEM_MODE
            ORDER BY BodyLength ASC
        ];
    }

    /**
     * The BYTES of exactly the carriers the caller has already decided it can afford.
     *
     * 🔴 THIS QUERY ALLOCATES `BodyLength` BYTES OF HEAP PER ROW. It must only ever be called
     * with the subset `AttachmentPersistQueueable.chooseConvertibleSubset(...)` returned, never
     * with "all carriers for this staging row" — that is precisely the difference between a
     * pre-check and a heap blow-out, and an Apex heap `LimitException` is UNCATCHABLE.
     *
     * @param ids The Attachment Ids whose bodies are needed; null or empty short-circuits
     *            without a query.
     * @return Matching rows including `Body`; an empty list when `ids` is null/empty or nothing
     *         matched (never null).
     * @example
     * List<Attachment> bodies = AttachmentSelector.selectBodiesByIds(chosenIds);
     */
    public static List<Attachment> selectBodiesByIds(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) {
            return new List<Attachment>();
        }
        return [
            SELECT Id, Name, ContentType, BodyLength, ParentId, Body
            FROM Attachment
            WHERE Id IN :ids
            WITH SYSTEM_MODE
        ];
    }
}
