/**
 * Selector for the standard ContentNote object. Encapsulates ALL SOQL against
 * ContentNote per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4, Module B2 — Property Management. In-scope consumer:
 *   • BrokerAssignmentController.getNotes -> selectByIdsOrderedByCreatedDateDesc
 * getNotes first collects a record's linked ContentDocument Ids (via
 * ContentDocumentLinkSelector), then passes them here. Because a ContentNote shares
 * its Id with its underlying ContentDocument, filtering ContentNote by those
 * document Ids returns ONLY notes — attached files are naturally excluded.
 *
 * MODE — `WITH USER_MODE` (API 67). Design §3/§5 lists ContentNote as a
 * system/content selector run under USER_MODE *by intent*: notes are surfaced only
 * when shared with the running user. Only standard content fields are selected
 * (Title, TextPreview, CreatedDate, CreatedBy.Name).
 *
 * SHAPE — genuine bulk read: WHERE Id IN :ids takes a `Set<Id>` and returns a List,
 * matching design §4's "by ids: selectByIds(Set<Id>)" convention and the caller's
 * "N document Ids -> N notes" access. Null/empty input short-circuits to an empty
 * list (never null), so getNotes' `docIds.isEmpty()` early-return stays honoured.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #22, §4, §5)
 */
public with sharing class ContentNoteSelector {

    /**
     * ContentNotes for the supplied ContentDocument Ids, newest first — backs
     * BrokerAssignmentController.getNotes. The field set and
     * `ORDER BY CreatedDate DESC` mirror the original inline query.
     *
     * @param ids ContentDocument Ids (a ContentNote's Id == its document Id) to
     *            resolve into Notes; a null/empty set short-circuits.
     * @return Matching Notes (Id, Title, TextPreview, CreatedDate, CreatedBy.Name)
     *         ordered by CreatedDate DESC; an empty list when ids is null/empty or
     *         no notes match (never null).
     * @example
     * List<ContentNote> notes = ContentNoteSelector.selectByIdsOrderedByCreatedDateDesc(docIds);
     */
    public static List<ContentNote> selectByIdsOrderedByCreatedDateDesc(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) {
            return new List<ContentNote>();
        }
        return [
            SELECT Id, Title, TextPreview, CreatedDate, CreatedBy.Name
            FROM ContentNote
            WHERE Id IN :ids
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];
    }
}
