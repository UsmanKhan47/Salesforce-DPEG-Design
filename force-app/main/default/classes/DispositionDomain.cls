/**
 * Domain layer for `Disposition__c` — in-memory derivations over loaded Disposition rows.
 * Zero SOQL, zero DML, zero callouts (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md).
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS CLASS EXISTS: TWO COPIES OF ONE HELPER DISAGREED, AND IT WAS INVISIBLE
 * ══════════════════════════════════════════════════════════════════════════════
 * Created 2026-08-19 by the disposition-redesign code review (finding C-2). Until then
 * `recordTypeNameOf(Disposition__c)` existed TWICE, privately:
 *
 *   `DispositionApprovalService.recordTypeNameOf`       returned **null**      for Master/unset
 *   `DispositionApprovalAdvanceService.recordTypeNameOf` returned **On_Market** for Master/unset
 *
 * The first one's own Javadoc asserted the two agreed. They did not, and the disagreement was
 * silently reachable end-to-end: a Master-type row read `null`, so
 * `submitForApproval`'s `RT_ON_MARKET.equals(recordType)` guard was FALSE, so the click fell into
 * the OFF-MARKET `Broker Selection` branch and submitted `Broker_Selection_Approval`. The
 * principals approved it, the semaphore fired, and the advance service then mapped the SAME row as
 * `On_Market|Broker Selection` — a key deliberately ABSENT from `ADVANCE_TARGET` — so the advance
 * `continue`d, the stage never moved and `Approval_Advance_Pending__c` stayed stuck true with
 * nothing on screen to say why.
 *
 * ⚠ NOTHING BUT A COMMENT WAS KEEPING THE TWO IN STEP, AND THE COMMENT WAS WRONG. That is the
 * whole argument for a single implementation: the defect was not a typo, it was two authors each
 * making a defensible local choice. One method makes the choice unmakeable twice.
 *
 * ── 🔴 THE ANSWER FOR A MASTER / UNSET ROW IS `On_Market`, AND IT IS CHOSEN ──
 * `On_Market` is also `RecordStageAdvanceService`'s `defaultTypeKey` for this object, so a
 * Master-type row gets the SAME answer from the manual-hop map, the approval-target map and the
 * submit dispatch. Two components disagreeing about what "no record type" means produces a
 * disposition whose Advance button and whose approvals walk different paths — which is exactly
 * what C-2 was. Any caller that genuinely needs to distinguish "Master" from "On_Market" must ask
 * a different question (read `RecordTypeId` itself); it must NOT reintroduce a second copy of this
 * method with a different default.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * Domain (ARCHITECTURE.md §2). It reads a field off a row the CALLER loaded and resolves it
 * through a DESCRIBE — `getRecordTypeInfosById()` is a platform-held map, not a query, so this
 * costs no SOQL at any record count and is safe to call inside a loop over a trigger chunk.
 *
 * ⚠ IT DOES NOT QUERY, SO THE CALLER MUST SELECT `RecordTypeId`. A `get('RecordTypeId')` on a row
 * whose SELECT omitted the field throws `System.SObjectException`, which is why every selector
 * feeding this class (`DispositionSelector.selectApprovalContextById`,
 * `.selectStageAndTypeByIds`, `.selectStageRequiredById`) lists the field explicitly and says so
 * in its own Javadoc.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * Pure function of one row, with no state and no limits consumption, so
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate has nothing to bind to here — the rule
 * binds to its CALLERS, and `DispositionApprovalAdvanceService` already carries the 251-row bulk
 * proof that exercises this method once per row.
 *
 * @see force-app/main/default/classes/DispositionApprovalService.cls (submit dispatch)
 * @see force-app/main/default/classes/DispositionApprovalAdvanceService.cls (approval advance map)
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls (manual-hop map)
 * @see force-app/main/default/classes/DispositionService.cls (create-time record-type allow-list)
 */
public with sharing class DispositionDomain {

    /**
     * `Disposition__c` record type developer names — THE canonical pair for this module.
     *
     * 🔴 EVERY OTHER CLASS THAT NEEDS THEM DERIVES FROM HERE RATHER THAN RE-DECLARING A LITERAL.
     * Case must match objects/Disposition__c/recordTypes/ exactly: these strings are compared
     * against `getRecordTypeInfosByDeveloperName()`'s CASE-SENSITIVE map keys and are also half of
     * every key in `DispositionApprovalAdvanceService.ADVANCE_TARGET` (Apex `Map<String, …>` keys
     * are case-SENSITIVE too), so a mis-cased literal maps nothing, throws nothing, and strands
     * every semaphore at true.
     *
     * ⚠ Four classes previously held their own literal pair. They now hold a `private static final`
     * ALIAS assigned from these two — the local name is kept because it reads better at the point
     * of use, but the VALUE has exactly one source. Do not "inline" an alias back to a literal.
     *
     * 🔴 EXACTLY ONE EXEMPTION, AND IT IS DELIBERATE: `TestDataFactory.DISPOSITION_RT_ON_MARKET` /
     * `DISPOSITION_RT_OFF_MARKET` KEEP THEIR OWN LITERALS. Do not "fix" them to point here. The
     * factory is the ONLY thing left in the test suite that is not downstream of this pair —
     * `DispositionApprovalService`, `DispositionApprovalAdvanceService` (including every
     * `ADVANCE_TARGET` key) and `DispositionDomainTest` all alias these constants, so a mis-casing
     * HERE would propagate identically into the fixtures, the maps and the assertions, every
     * comparison would still match itself, and the whole suite would stay GREEN while
     * `getRecordTypeInfosByDeveloperName()` matched nothing in the org — the precise failure this
     * class exists to prevent. The independent literal is what makes
     * `TestDataFactoryTest.createDisposition_caseTypoRecordTypeName_throwsAndNamesTheOffendingValue`
     * a real falsifier rather than a tautology. If the two pairs ever disagree, THAT IS THE TEST
     * WORKING: fix the wrong one, do not collapse them.
     */
    public static final String RT_ON_MARKET = 'On_Market';
    public static final String RT_OFF_MARKET = 'Off_Market';

    /**
     * The record type developer name of a LOADED Disposition, defaulting a Master / unset row to
     * `RT_ON_MARKET`.
     *
     * A DESCRIBE, not a query — it costs no SOQL.
     *
     * @param disposition a Disposition whose SELECT included `RecordTypeId`. Null-safe.
     * @return `On_Market`, `Off_Market`, or — for a null row, a null `RecordTypeId`, a Master row,
     *         or an Id this org no longer resolves — `RT_ON_MARKET`. NEVER null: a null answer is
     *         what let the C-2 defect through an `equals` guard undetected.
     * @example
     * String type = DispositionDomain.recordTypeNameOf(disposition);
     */
    public static String recordTypeNameOf(Disposition__c disposition) {
        if (disposition == null || disposition.RecordTypeId == null) {
            return RT_ON_MARKET;
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosById()
            .get(disposition.RecordTypeId);
        return (info == null || info.isMaster()) ? RT_ON_MARKET : info.getDeveloperName();
    }
}
