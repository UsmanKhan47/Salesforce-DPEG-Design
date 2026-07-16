/**
 * Selector for the standard ContentDocumentLink object. Encapsulates ALL SOQL
 * against ContentDocumentLink per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * P4, Module B2 — Property Management. In-scope consumer:
 *   • BrokerAssignmentController.getNotes -> selectByLinkedEntityId
 * getNotes resolves a record's linked ContentDocument Ids, then hands them to
 * ContentNoteSelector to fetch only the Notes (files are naturally excluded because
 * a ContentNote shares its Id with its underlying ContentDocument).
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
}
