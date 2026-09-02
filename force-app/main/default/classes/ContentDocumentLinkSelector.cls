/**
 * Selector for the standard ContentDocumentLink object. Encapsulates ALL SOQL
 * against ContentDocumentLink per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * CONSUMERS (authoritative — a stale list here tells the next reviewer this selector is
 * single-module when it is not):
 *   • BrokerAssignmentController.getNotes    -> selectByLinkedEntityId   (P4, Module B2 —
 *     Property Management). Resolves a record's linked ContentDocument Ids, then hands them to
 *     ContentNoteSelector to fetch only the Notes (files are naturally excluded because a
 *     ContentNote shares its Id with its underlying ContentDocument).
 *   • ChecklistCaptureService                -> selectByLinkedEntityIds  (Transactions, Phase 5,
 *     added 2026-09-02). Two uses, both READS and therefore both free of ContentPublication quota:
 *     the C7 / G6 completion guard ("has this checklist ITEM got a document on file?") and the
 *     duplicate check before inserting a ContentDocumentLink.
 * ⚠ THIS IS NOW A CROSS-MODULE SELECTOR (Property Management + Transactions). Neither method may
 * be narrowed to one module's needs without checking the other.
 *
 * MODE — `WITH USER_MODE` (API 67). Design §3/§5 lists ContentDocumentLink as a
 * system/content selector run under USER_MODE *by intent*: the running user should
 * only see documents shared with them, so USER_MODE's sharing enforcement is the
 * desired behaviour, not a risk. Only standard content fields are selected.
 *
 * SHAPE — single-parent read. getNotes is inherently "all links for ONE record"
 * (getNotes(Id recordId)), so this takes a single LinkedEntityId and returns a
 * List, matching design §4's "single-parent child list: selectByParentId(Id)"
 * convention. No `Set<Id>` overload is added because no consumer queries links for
 * many parents at once — a dead bulk method would violate this pass's one-change
 * scope (pilot WireSelector rationale). The 251-row bulk read is still exercised in
 * the SelectorTest by linking 251 documents to one entity.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #21, §4, §5)
 */
public with sharing class ContentDocumentLinkSelector {

    /**
     * All ContentDocumentLinks for one linked entity — backs
     * BrokerAssignmentController.getNotes, which reads ContentDocumentId off each
     * row to build the set of document Ids to resolve into Notes.
     *
     * @param linkedEntityId Record the documents are linked to (e.g. a
     *                       Broker_Assignment__c Id); a null id short-circuits.
     * @return Matching links (Id, ContentDocumentId, LinkedEntityId); an empty list
     *         when linkedEntityId is null or nothing is linked (never null).
     * @example
     * List<ContentDocumentLink> links =
     *     ContentDocumentLinkSelector.selectByLinkedEntityId(recordId);
     */
    public static List<ContentDocumentLink> selectByLinkedEntityId(Id linkedEntityId) {
        if (linkedEntityId == null) {
            return new List<ContentDocumentLink>();
        }
        return [
            SELECT Id, ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :linkedEntityId
            WITH USER_MODE
        ];
    }

    /**
     * The same read for MANY parents at once — added 2026-09-02 for
     * `ChecklistCaptureService`, which asks "does every C7 / G6 item in this
     * completion batch have a document on file?" and must answer it in ONE query
     * however many items the batch carries.
     *
     * ⚠ THE "NO DEAD BULK METHOD" REASONING IN THE HEADER ABOVE IS SATISFIED, NOT
     * OVERRIDDEN. That paragraph declines a `Set<Id>` overload *while no consumer
     * queries links for many parents at once*. One now does, and it is a genuine
     * bulk consumer: the checklist completion service accepts a collection and its
     * document guard must not become one query per item.
     *
     * 🔴 THIS IS A READ, SO IT COSTS NO `ContentPublication` QUOTA AT ALL, AND THAT
     * IS THE POINT OF ROUTING THE PHASE 5 DOCUMENT GUARD THROUGH IT. Only a
     * `ContentVersion` / `ContentNote` INSERT consumes the org-wide 2,500-per-24-hours
     * cap (`.claude/rules/content-publication-rule.md`); querying links and inserting
     * `ContentDocumentLink` rows consume none of it. Any test of this method is a
     * SELECTOR READ and is capped at 20 content rows by that rule — behaviour at 251
     * rows is identical, because a query has no trigger-batch chunking for the
     * 251-record mandate to expose.
     *
     * ⚠ `LinkedEntityId` supports `IN` in a `ContentDocumentLink` filter; the object
     * requires a filter on `ContentDocumentId` or `LinkedEntityId`, and this satisfies
     * that requirement.
     *
     * @param linkedEntityIds Records the documents are linked to; null/empty-safe.
     * @return Matching links (Id, ContentDocumentId, LinkedEntityId) across every
     *         supplied parent; an empty list when the input is empty or nothing is
     *         linked (never null). The caller groups by `LinkedEntityId`.
     * @example
     * List&lt;ContentDocumentLink&gt; links =
     *     ContentDocumentLinkSelector.selectByLinkedEntityIds(itemIds);
     */
    public static List<ContentDocumentLink> selectByLinkedEntityIds(Set<Id> linkedEntityIds) {
        if (linkedEntityIds == null || linkedEntityIds.isEmpty()) {
            return new List<ContentDocumentLink>();
        }
        return [
            SELECT Id, ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :linkedEntityIds
            WITH USER_MODE
        ];
    }
}
