/**
 * Reads `Unit__c` by its Yardi external id, for the receivables feed join.
 *
 * ==========================================================================================
 * DELIBERATE, TEMPORARY DEVIATION FROM ONE-SELECTOR-PER-OBJECT - READ BEFORE EXTENDING
 * ==========================================================================================
 * `.claude/rules/apex-layering-rule.md` says all SOQL for an object lives in that object's selector,
 * and `UnitSelector` already exists. This method belongs there and is NOT there for one reason:
 *
 *   On 2026-08-22 `UnitSelector.cls` was already MODIFIED IN THIS WORKING TREE by a concurrent
 *   build stream (confirmed via `git status`). Adding a method to it would have meant deploying that
 *   stream's unreviewed, in-flight edit as part of this feature's payload - the exact hazard this
 *   repo has already been bitten by, where a second session's work silently unioned into shared
 *   files and failed a deploy on the other stream's undeployed field.
 *
 * CONSOLIDATION IS OWED. Once the concurrent stream lands, `selectByYardiUnitIds` should be moved
 * into `UnitSelector` verbatim and this class deleted; the only caller is
 * `ReceivablesSyncService`, so it is a two-line change. Do not add a second method here in the
 * meantime - that would turn a temporary deviation into a parallel selector.
 *
 * MODE - `WITH SYSTEM_MODE`. Automation path: the nightly ingest performs this read on the
 * scheduling principal's behalf. Contrast `UnitSelector`, whose methods are `USER_MODE` because each
 * backs a read a human explicitly asked for (the rent-roll card, the suite picker). The mode is a
 * property of the METHOD, not of the object.
 *
 * SHARING - `with sharing`, NOT escaped, and that is a considered answer rather than an omission.
 * `Unit__c` OWD is `ControlledByParent` (verified 2026-08-22) - it inherits `Property_Asset__c`. An
 * unmatched unit degrades gracefully by design: `ReceivablesSummaryDomain` leaves the Unit and
 * Property Asset lookups null and the mirror row still lands, the Case still opens, the lifecycle
 * still runs. So a sharing miss here costs navigability, not correctness, and does not justify an
 * escape. RESIDUAL: if the scheduling principal cannot see a property asset, that property's mirror
 * rows lose their Unit link silently. Visible as null `Property_Asset__c` in the section 6.5 reports.
 *
 * @see ReceivablesSyncService.cls (the only caller)
 * @see UnitSelector.cls           (where this method belongs once the concurrent stream lands)
 */
public with sharing class ReceivablesUnitSelector {

    /**
     * Units by their Yardi external id, keyed for a map join.
     *
     * @param yardiUnitIds `Unit__c.Yardi_Unit_Id__c` values; null/empty safe.
     * @return Map of `Yardi_Unit_Id__c` to Unit, carrying only what the mirror mapping needs (Id,
     *         master Property Asset, tenant label, current rent). Never null; unmatched keys are
     *         simply absent.
     * @example
     * Map&lt;String, Unit__c&gt; units =
     *     ReceivablesUnitSelector.selectByYardiUnitIds(new Set&lt;String&gt;{ 'YU-0000000001' });
     */
    public static Map<String, Unit__c> selectByYardiUnitIds(Set<String> yardiUnitIds) {
        Map<String, Unit__c> unitsByKey = new Map<String, Unit__c>();
        if (yardiUnitIds == null || yardiUnitIds.isEmpty()) {
            return unitsByKey;
        }
        for (Unit__c unit : [
            SELECT Id, Yardi_Unit_Id__c, Property_Asset__c, Tenant_Name__c, Current_Monthly_Rent__c
            FROM Unit__c
            WHERE Yardi_Unit_Id__c IN :yardiUnitIds
            WITH SYSTEM_MODE
        ]) {
            unitsByKey.put(unit.Yardi_Unit_Id__c, unit);
        }
        return unitsByKey;
    }
}
