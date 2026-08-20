/**
 * Selector for BOV_Broker_Change__c — all SOQL against the disposition BOV's append-only
 * broker-replacement log, per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL
 * must live in Selector classes. Nothing else queries that object.").
 *
 * Added 2026-08-20 with Tranche 2 Workstream B (design D4.6), alongside the object itself. Its one
 * consumer is `BovBrokerChangeController.getHistory`, which backs `c/bovBrokerChangeHistory` on the
 * Disposition record page. The WRITER is `BovSubmissionService.replaceSelectedBroker` — nothing in
 * this class writes, and nothing anywhere else reads.
 *
 * ── MODE: WITH USER_MODE, AND THIS IS THE CASE THE RULE WAS WRITTEN FOR ──────
 * This is a read the running user ASKED FOR: they opened a Disposition record page and this card is
 * on it. ARCHITECTURE.md §2's automation-path exception (`WITH SYSTEM_MODE`) explicitly does not
 * apply to that shape — a throw here reports a real provisioning gap and the fix is a permission
 * set, not a mode change. `DPEG_Disposition_View` and `DPEG_Disposition_Edit` both grant READ on
 * every column below, which is the whole of what this class needs; USER_MODE is what makes the code
 * stop being correct if that read grant is ever lost in a permission-set deploy — which this repo
 * has watched happen, because a PermissionSet deploy REPLACES its whole fieldPermissions set.
 *
 * ── ⚠ RETRACTED 2026-08-20 (re-review N1): THE "read+edit" CLAIM THAT USED TO SIT HERE ──────
 * This header previously said: *"`DPEG_Disposition_View` grants read and `DPEG_Disposition_Edit`
 * read+edit on every column below (see the object's own header)"*. **That is no longer true, and it
 * must not be "restored".** Both permission sets are now READ-ONLY on `BOV_Broker_Change__c`:
 * `allowCreate` / `allowEdit` / `allowDelete` are false, and all 11 fields are `editable=false`.
 *
 * That is a DELIBERATE FIX, not drift. The whole value of this log is that it records WHO replaced a
 * broker and WHEN; an actor who can edit `Logged_By__c` or `Entry_DateTime__c` after the fact can
 * rewrite that record of themselves, which makes the log worth less than no log at all. Every row is
 * written by `BovSubmissionService.replaceSelectedBroker` in Apex — no human is supposed to type into
 * this object, so no human needs edit on it.
 *
 * 🔴 THE HAZARD THIS RETRACTION EXISTS TO PREVENT. A future reader who opens the permission sets,
 * finds `editable=false` on all 11 fields, and compares that against a header promising "read+edit"
 * can quite reasonably conclude the edit grants were dropped ACCIDENTALLY by a wholesale
 * `fieldPermissions` replace — a thing that has genuinely happened in this repo — and put them back,
 * silently undoing the tamper-proofing with no test anywhere going red. The read-only state IS the
 * intended state. Anyone widening it needs a new decision, not a restoration.
 * ⚠ AND THE CROSS-REFERENCE MADE IT WORSE RATHER THAN CATCHING IT: the retracted sentence pointed the
 * reader at the OBJECT's own header, which carried the identical stale claim. The two files agreed
 * with each other, so neither contradicted the wrong one and there was nothing to notice. (The object
 * header is being corrected separately.)
 * ⚠ NO RUNTIME EFFECT EITHER WAY. This class only READS, read is granted, and nothing here or in
 * `BovBrokerChangeController` writes — the correction is to the header's accuracy, not to behaviour.
 *
 * 🔴 WHOEVER ADDS A FIELD TO THE SELECT BELOW MUST RE-CHECK THE FLS GRANT MATRIX FIRST. `USER_MODE`
 * THROWS, IT DOES NOT DEGRADE: one column the running user cannot read raises
 * `System.QueryException: No such column 'X__c'` — an FLS denial wearing a schema error — and takes
 * the ENTIRE card down for every user, not just the new column. A Metadata-API-deployed custom
 * field arrives with NO FLS for anyone, System Administrator included, so a field added here and
 * granted in a later deploy blanks the card in between.
 *
 * ⚠ THE Contact LOOKUPS ARE DELIBERATELY NOT TRAVERSED. `Outgoing_Broker__r.Name` /
 * `Incoming_Broker__r.Name` would read a STANDARD object this module never otherwise reads, and
 * under USER_MODE an absent Contact grant would take the whole history card down over a name that
 * is already available: `Outgoing_Broker_Firm__c` / `Incoming_Broker_Firm__c` are stamped snapshots
 * written at replacement time precisely so this read does not have to depend on the Contact still
 * existing (both lookups are deleteConstraint SetNull and scripts/seed-broker-contacts.apex
 * mass-deletes broker Contacts). The firm string is the display value; the lookups are for
 * reporting and drill-through. Contrast `Logged_By__r.Name`, which IS traversed — see below.
 *
 * ⚠ `Logged_By__r.Name` IS TRAVERSED, and safely: the lookup field itself is enforced under
 * USER_MODE like any other custom column, and `User.Name` is a standard, always-readable field.
 * Same traversal, same justification, as `LeaseActivitySelector` — the sibling append-only log this
 * class is modelled on.
 *
 * ORDER: newest first on `Entry_DateTime__c` (the append-only-log timeline stamp shared with
 * `Lease_Activity__c` / `Deal_Message__c`), tie-broken on `Name DESC` for rows written in the same
 * transaction, which share a frozen clock in tests and would otherwise return in an arbitrary
 * order. ⚠ `Name` is the AutoNumber `BBC-{0000}`, so the tie-break is a LEXICAL sort and would
 * order `BBC-10000` before `BBC-9999` after ten thousand replacements on one disposition. That is
 * accepted, exactly as `LeaseActivitySelector` accepts it: it only decides the order of rows
 * sharing a single DateTime, and one disposition reaching four figures of broker swaps is not a
 * state this application has.
 *
 * NOT-FOUND CONTRACT — read-for-display. 🔴 A DISPOSITION WITH NO BROKER CHANGES IS THE NORMAL
 * CASE, NOT AN EDGE CASE: most sales never replace a broker at all. The method returns its natural
 * empty List and never null and never throws for it, so the client can render "No broker changes
 * recorded" without having to distinguish empty from broken.
 *
 * @see force-app/main/default/classes/BovSubmissionService.cls (the only writer)
 * @see force-app/main/default/classes/LeaseActivitySelector.cls (sibling append-only-log template)
 */
public with sharing class BovBrokerChangeSelector {

    /**
     * A defensive cap, not a page size.
     *
     * ⚠ IT IS NOT EXPECTED TO BE REACHED BY ANY REAL DISPOSITION — a sale that replaced its broker
     * two hundred times is a data defect, and this constant exists so that defect degrades a card
     * instead of blowing the 50,000-row query limit for the whole page. The client renders the rows
     * it is given; it does not paginate.
     */
    @TestVisible
    private static final Integer HISTORY_LIMIT = 200;

    /**
     * Every recorded broker change for one Disposition, newest first — backs
     * `BovBrokerChangeController.getHistory` and `c/bovBrokerChangeHistory`.
     *
     * The field list is exactly the set `BovBrokerChangeController.ChangeRow` maps, plus the
     * `Disposition__c` anchor (the parent key, included on the same grounds as
     * `LeaseActivitySelector`'s). Narrowing it would reintroduce a "row retrieved via SOQL without
     * querying the requested field" defect; widening it is the FLS hazard described at length in
     * the class header.
     *
     * ⚠ `Outgoing_BOV_Submission__c` / `Incoming_BOV_Submission__c` ARE NOT SELECTED, THOUGH THEY
     * ARE WRITTEN. Nothing displays them today, and under USER_MODE every unused column in a SELECT
     * is a live way for a future permission-set deploy to take the whole card down for a value
     * nobody was looking at. Add them WITH a consumer, not in anticipation of one.
     *
     * @param dispositionId Disposition__c Id whose broker-change history to read; null-safe.
     * @return Ordered BOV_Broker_Change__c rows (with `Logged_By__r.Name` populated); an EMPTY LIST
     *         — never null — when the disposition has no recorded changes, which is the normal
     *         state for most dispositions.
     * @example
     * List&lt;BOV_Broker_Change__c&gt; changes =
     *     BovBrokerChangeSelector.selectByDispositionId(dispId);
     */
    public static List<BOV_Broker_Change__c> selectByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<BOV_Broker_Change__c>();
        }
        return [
            SELECT Id, Name, Disposition__c,
                   Outgoing_Broker_Firm__c, Incoming_Broker_Firm__c,
                   Reason__c, Notes__c, Entry_DateTime__c, Logged_By__r.Name
            FROM BOV_Broker_Change__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
            LIMIT :HISTORY_LIMIT
        ];
    }
}
