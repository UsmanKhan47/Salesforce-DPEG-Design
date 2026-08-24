/**
 * Selector for `Release_Materials_Response__c` — ALL SOQL against the Release Materials response
 * log, per ARCHITECTURE.md §2 and `.claude/rules/apex-layering-rule.md` ("All SOQL must live in
 * Selector classes. Nothing else queries that object.").
 *
 * Added 2026-08-24 with the Release Materials response logger. Two consumers, both reads:
 *   `ReleaseMaterialsResponseService.getLogContext`  -> `c/releaseMaterialsResponseLog`
 *   `DispositionBuyerTimelineService.getTimeline`    -> `c/dispositionBuyerTimeline` (the MERGED
 *                                                       Buyer Activity timeline)
 * The one WRITER is `ReleaseMaterialsResponseService.logResponse`; nothing in this class writes.
 *
 * ── MODE: `WITH USER_MODE`, DECIDED HERE RATHER THAN COPIED ─────────────────────────────────
 * Both reads are reads a human ASKED FOR — they opened a Disposition record page and one of these
 * two cards is on it. ARCHITECTURE.md §2's automation-path `SYSTEM_MODE` exception explicitly does
 * not cover that shape: there is no trigger to roll back and no batch to disable, so a throw here
 * reports a real provisioning gap and the fix is a permission set.
 *
 * 🔴 AND THE GRANTS WERE MEASURED IN `usman-dpeg` ON 2026-08-24 RATHER THAN READ OFF THE
 * PERMISSION-SET XML — a permission-set GROUP unions its members, so the XML of one member is not
 * the effective answer. `SELECT Parent.Name, Field, PermissionsRead FROM FieldPermissions WHERE
 * SobjectType = 'Release_Materials_Response__c'` returned read = true on ALL FIVE custom fields
 * (`Method__c`, `Broker__c`, `Notes__c`, `Disposition__c`, `Entry_DateTime__c`) for
 * `DPEG_Disposition_View`, `DPEG_Disposition_Edit`, `DPEG_Principal_PSG` and
 * `DPEG_Junior_Analyst_PSG`. So USER_MODE costs nothing today and is what makes this card stop
 * being correct if a grant is ever lost — which this repo has watched happen, because a
 * PermissionSet deploy REPLACES its whole `fieldPermissions` set.
 *
 * 🔴 WHOEVER ADDS A FIELD TO THE SELECT BELOW MUST RE-CHECK THAT MATRIX FIRST. `USER_MODE` THROWS,
 * IT DOES NOT DEGRADE: one column the running user cannot read raises
 * `System.QueryException: No such column 'X__c'` — an FLS denial wearing a schema error — and takes
 * BOTH cards down for every user, not just the new column. A Metadata-API-deployed custom field
 * arrives with NO FLS for anyone, System Administrator included, so a field added here and granted
 * in a later deploy blanks both cards in between.
 *
 * ── SHARING: `with sharing`, AND UNDER-COUNTING IS STRUCTURALLY IMPOSSIBLE TODAY ─────────────
 * `Release_Materials_Response__c` is Private OWD, and BOTH disposition permission sets carry
 * `viewAllRecords = true` on it (measured; the object's own header records that this is why no
 * sharing rule ships). So every row on the disposition is visible to every disposition persona and
 * the `with sharing` keyword removes nothing today. It stays because the day someone drops
 * `viewAllRecords` in favour of a criteria rule, this class must follow the rule rather than
 * silently outrun it. 🔴 DO NOT ADD A `without sharing` INNER CLASS HERE: an under-count on a card
 * a human is reading is VISIBLE (the related list beside it is scoped the same way), which is the
 * only failure shape that has ever justified one in this repo.
 *
 * ── 🔴 `Broker__r.Name` IS TRAVERSED, AND IT ADDS AN **OBJECT-LEVEL** GATE ON `Contact` ──────
 * `USER_MODE` enforces object-level read on the RELATED object, and neither `DPEG_Disposition_View`
 * nor `DPEG_Disposition_Edit` grants `Contact` — that lives in `DPEG_Contact_View` /
 * `DPEG_Contact_Edit`, separate members of the same permission-set GROUPS. So this works for both
 * intended personas TODAY and it is a CROSS-PERMISSION-SET COUPLING: a persona assembled from the
 * disposition set alone hits `QueryException` on the traversal, and the fix is to add the Contact
 * set, never to switch this query to `SYSTEM_MODE`.
 * ⚠ `Contact.Name` itself is `permissionable = false` and is always readable, so the gate is the
 * OBJECT, not the field. This is the identical gate `NdaSelector.selectBuyerTimelineByDispositionId`
 * carries for the identical reason; the two cards fail together, which is the correct behaviour
 * (they are the same data on the same page).
 * ⚠ THE TRAVERSAL IS DELIBERATE AND HAS NO STAMPED ALTERNATIVE. `BovBrokerChangeSelector` refuses
 * the same traversal because that object carries `*_Broker_Firm__c` TEXT snapshots to display
 * instead. This object has NO name snapshot — the response row carries only the lookup — so
 * refusing the traversal would leave the card with a raw Id and nothing to render.
 *
 * ORDER: newest first on `Entry_DateTime__c`, tie-broken on `Name DESC` for rows written in the
 * same transaction, which share a frozen clock in tests and would otherwise return in an arbitrary
 * order. ⚠ `Name` is the AutoNumber `RMR-{0000}`, so the tie-break is a LEXICAL sort and would
 * order `RMR-10000` before `RMR-9999` after ten thousand responses on one disposition. Accepted on
 * exactly the grounds `BovBrokerChangeSelector` and `LeaseActivitySelector` accept it: it only
 * decides the order of rows sharing a single DateTime.
 * ⚠ `NULLS LAST` IS EXPLICIT AND IS LOAD-BEARING. `Entry_DateTime__c` defaults to `NOW()` but is
 * NOT `required`, so an API/data-loader row can carry null; the platform's default for `DESC` is
 * NULLS FIRST, which would float an undated row above every real one on both cards.
 *
 * NOT-FOUND CONTRACT — read-for-display. 🔴 A DISPOSITION WITH NO RESPONSES IS THE NORMAL CASE,
 * NOT AN EDGE CASE: nothing has been logged until materials go out and a broker replies. The method
 * returns its natural empty List, never null and never a throw, so both clients can render an empty
 * state without having to distinguish empty from broken.
 *
 * @see force-app/main/default/classes/ReleaseMaterialsResponseService.cls (the only writer)
 * @see force-app/main/default/classes/BovBrokerChangeSelector.cls (sibling append-only-log template)
 * @see force-app/main/default/classes/DispositionBuyerTimelineService.cls (the merged timeline)
 */
public with sharing class ReleaseMaterialsResponseSelector {

    /**
     * A defensive cap, not a page size.
     *
     * ⚠ IT IS NOT EXPECTED TO BE REACHED BY ANY REAL DISPOSITION — a sale that logged two hundred
     * broker responses is remarkable, and this constant exists so that case degrades a card instead
     * of contributing to a page-wide row-limit or heap failure. The clients render the rows they are
     * given; neither paginates.
     *
     * 🔴 THE TRUNCATION DIRECTION IS THE WHOLE REASON A CAP IS ACCEPTABLE HERE AND IS REFUSED ON
     * THE NDA TIMELINE. This read is `ORDER BY Entry_DateTime__c DESC`, so a cap keeps the NEWEST
     * rows — what anyone reading a log wants. `NdaSelector.selectBuyerTimelineByDispositionId`
     * refuses a `LIMIT` precisely because it is ordered ASC, where a cap would silently discard the
     * most recently engaged parties. Same page, two orderings, two opposite answers; read that
     * method's header before "harmonising" them.
     */
    @TestVisible
    private static final Integer LOG_LIMIT = 200;

    /**
     * Every logged response for one Disposition, newest first — backs BOTH the logger card's own
     * list and the merged Buyer Activity timeline.
     *
     * The field list is exactly the set the two DTO builders map, plus the `Disposition__c` anchor
     * (the parent key, included on the same grounds as `BovBrokerChangeSelector`'s). Narrowing it
     * would reintroduce a "row retrieved via SOQL without querying the requested field" defect;
     * widening it is the FLS hazard described at length in the class header.
     *
     * ⚠ `CreatedDate` IS DELIBERATELY NOT SELECTED EVEN THOUGH THE MERGED TIMELINE SORTS ON A
     * TIMESTAMP. `Entry_DateTime__c` is the timeline stamp for this object — it is what a user can
     * BACKDATE when recording a response that happened yesterday, and the field's own help text
     * says so. Sorting the merged card on `CreatedDate` would put a backdated response at the top
     * of the timeline, which is the one thing backdating exists to prevent.
     *
     * @param dispositionId Disposition__c Id whose responses to read; null-safe.
     * @return Ordered `Release_Materials_Response__c` rows (with `Broker__r.Name` populated); an
     *         EMPTY LIST — never null — when the disposition has no responses, which is the normal
     *         state until materials go out.
     * @throws System.QueryException when the running user lacks read on
     *         `Release_Materials_Response__c`, on any of the five custom fields, or OBJECT read on
     *         `Contact` (the `Broker__r` traversal). Both callers let it propagate to their
     *         controller, which converts it to a user-safe `AuraHandledException`.
     * @example
     * List&lt;Release_Materials_Response__c&gt; rows =
     *     ReleaseMaterialsResponseSelector.selectByDispositionId(dispositionId);
     */
    public static List<Release_Materials_Response__c> selectByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<Release_Materials_Response__c>();
        }
        return [
            SELECT Id, Name, Disposition__c, Method__c, Notes__c,
                   Entry_DateTime__c, Broker__c, Broker__r.Name
            FROM Release_Materials_Response__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
            LIMIT :LOG_LIMIT
        ];
    }
}
