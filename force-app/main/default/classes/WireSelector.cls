/**
 * Selector for Wire__c. Encapsulates ALL SOQL against Wire__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * PILOT NOTE (P4, Module D — Disposition): this is the first selector in the
 * codebase and the template the other four modules copy. Two design points
 * resolved here that the rollout inherits:
 *
 *  1. MODE — every query uses `WITH USER_MODE` (API 67). Wire__c is a custom
 *     object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe
 *     and enforces the running user's sharing + FLS. There is NO guest path
 *     for Disposition/Wire, so NO `SYSTEM_MODE` appears here.
 *
 *  2. NOT-FOUND CONTRACT is per-caller, and the method shape encodes it:
 *       - read-for-display  (getWire)  -> a missing Wire__c is normal; return
 *         SObject-or-null. See selectMostRecentByDispositionId.
 *       - fetch-for-update  (saveWire) -> the caller passed a specific Id it
 *         expects to exist; a miss is an error. A single-row SOQL assignment
 *         throws the native System.QueryException. See selectRequiredById.
 *     Selectors do not invent business exceptions; they either return
 *     null/empty or let the native single-row-assignment exception fly.
 *
 * Both methods here are single-record because both relocated queries are
 * single-record UI reads (one Disposition -> one Wire row for the LWC; one
 * Wire Id -> one record to update). This module has NO bulk/child-by-parent
 * consumer, so no `Set<Id>` method is added — a dead bulk method would
 * violate the "one change, one reason" scope of this pass. Modules that DO
 * query children by a set of parent Ids must add bulk `selectByIds(Set<Id>)` /
 * `selectByXIds(Set<Id>)` methods returning List/Map, per the AccountSelector
 * reference and ARCHITECTURE.md §2's collections rule.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #6, §4, §5)
 */
public with sharing class WireSelector {

    /**
     * Most-recent Wire__c for one Disposition — backs WireController.getWire.
     * A Disposition with no Wire yet is a normal state, so this returns null
     * rather than throwing.
     *
     * @param dispositionId Disposition__c Id to read the latest Wire for.
     * @return The most recently created Wire__c for the Disposition
     *         (ORDER BY CreatedDate DESC, Id DESC LIMIT 1), or null when the
     *         input is null or the Disposition has no Wire.
     * @example
     * Wire__c latest = WireSelector.selectMostRecentByDispositionId(dispId);
     */
    public static Wire__c selectMostRecentByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return null;
        }
        List<Wire__c> wires = [
            SELECT Id, Verbal_Verification_Completed__c, Verifier_Name__c,
                   Verifier_Phone__c, Verified_DateTime__c, Wire_Instructions_Source__c,
                   Confirmed_Wire_Amount__c
            FROM Wire__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        return wires.isEmpty() ? null : wires[0];
    }

    /**
     * Fetches exactly one Wire__c by Id for the update path (backs
     * WireController.saveWire). Uses a single-row SOQL assignment: when the Id
     * resolves to no row, Apex throws System.QueryException
     * ("List has no rows for assignment to SObject"), preserving the existing
     * caller contract that a missing update target is an error.
     *
     * FIELD SET IS DELIBERATE: `Id, Verified_DateTime__c`. saveWire reads
     * Verified_DateTime__c on the returned record to decide whether to stamp it;
     * a `SELECT Id`-only query would reintroduce the
     * `System.SObjectException: row was retrieved via SOQL without querying the
     * requested field: Wire__c.Verified_DateTime__c` defect fixed earlier. Do
     * not narrow this field list.
     *
     * @param wireId Wire__c Id to load for update; must reference an existing row.
     * @return The Wire__c with Id and Verified_DateTime__c populated.
     * @throws System.QueryException when no Wire__c matches the Id.
     */
    public static Wire__c selectRequiredById(Id wireId) {
        return [
            SELECT Id, Verified_DateTime__c
            FROM Wire__c
            WHERE Id = :wireId
            WITH USER_MODE
        ];
    }
}
