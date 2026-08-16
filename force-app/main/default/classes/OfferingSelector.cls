/**
 * Selector for `Offering__c`. Encapsulates ALL SOQL against `Offering__c` per ARCHITECTURE.md §2
 * and `.claude/rules/apex-layering-rule.md` ("All SOQL must live in Selector classes. Nothing else
 * queries that object.").
 *
 * 🔴 THIS IS THE **FIRST AND ONLY** `Offering__c` SOQL IN THE APPLICATION. There was none before
 * it — verified repo-wide 2026-08-16: the object's only non-metadata reference was
 * `TestDataFactory.createOfferings` / `createOffering`. It is therefore the same kind of class as
 * `AccountSelector` (2026-08-02) and `OpportunityContactRoleSelector` (2026-08-03), and it carries
 * the same standing instruction: **every future `Offering__c` read belongs here**, not inlined into
 * whatever service needs it next.
 *
 * ── CONSUMER ────────────────────────────────────────────────────────────────
 * `OfferingService.ensureOnPsaExecuted` — the IDEMPOTENCY GUARD behind the Offering shell that is
 * created when an acquisition PSA is executed (FSD Tranche 1, Item 1). One consumer today, and the
 * method is shaped for it: a bulk, set-based existence read called ONCE per trigger chunk.
 *
 * ── MODE AND SHARING ARE TWO SEPARATE QUESTIONS AND BOTH ARE ANSWERED AT THE METHOD ──
 * The single method here is `WITH SYSTEM_MODE` and lives in a `private without sharing` inner
 * class, `ExecutionHandoffReads`. The OUTER class stays `with sharing`, so a future user-facing
 * read added here inherits the safe default rather than this method's escape. Conflating the two
 * keywords is the D25 mistake this repo has already paid for once; read
 * `selectByOpportunityIds`'s own Javadoc and `ExecutionHandoffReads`'s header, which argue them
 * separately.
 *
 * ── NOT-FOUND CONTRACT ──────────────────────────────────────────────────────
 * read-for-existence: the caller uses the result purely as a set-membership test, so the method
 * returns its natural empty `List` and never null.
 *
 * @see OfferingService.cls                 (the only consumer, and the Offering shell's whole story)
 * @see PropertyAssetSelector.cls           (`AssetCreationReads` — the shape this copies)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class OfferingSelector {

    /**
     * Every existing Offering for a set of Opportunities — the IDEMPOTENCY GUARD behind
     * `OfferingService.ensureOnPsaExecuted` ("never a second Offering shell for one deal").
     *
     * ⚠ THE KEY IS `Opportunity__c` ALONE, WITH NO `Status__c` FILTER, AND THAT IS THE DECISION
     * RATHER THAN AN OMISSION. A deal whose Offering has already been moved to `Active` or `Closed`
     * therefore gets NO second shell on a re-execution of its PSA. That is correct: the shell is a
     * handoff artifact for IR, and a second one would leave two rows under one deal with no reader
     * able to say which is the live one. `Offering__c.Status__c` is a lifecycle IR drives; it is
     * not an existence test.
     *
     * ⚠ THE FIELD SET IS DELIBERATELY MINIMAL (Id + `Opportunity__c`) and must stay that way. The
     * caller reads `Opportunity__c` and nothing else. This query runs on every acquisition PSA
     * execution, so each field added is another way for a PSA execution to fail.
     *
     * ═══ ▸ MODE = `WITH SYSTEM_MODE` — the AUTOMATION-PATH exception (ARCHITECTURE.md §2) ═══
     * Nobody asks for this read. It runs inside a `Contract_Review__c` AFTER-UPDATE trigger, on
     * behalf of whoever executed the PSA. `WITH USER_MODE` does not degrade, it THROWS — and a
     * throw there escapes the trigger as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`, which does not
     * merely skip the Offering: it **ROLLS BACK THE PSA EXECUTION ITSELF** — the Contract Review's
     * `Executed` status, `Contract_Signed__c`, Day 0 and the three team notifications. That is
     * verbatim the shape of the reproduced `TaskSelector.selectByTransactionDealIds` production
     * incident ARCHITECTURE.md records.
     *
     * ⚠ AND THE EXPOSURE IS CRUD, NOT MERELY FLS. Measured against this repo 2026-08-16:
     * `DPEG_Admin_Access` carries a `<tabSettings>` entry for `Offering__c` and **no
     * `objectPermissions` entry at all**, so a bare administrator has no `Offering__c` CRUD from
     * that set. Separately, the persona that EXECUTES a PSA is defined by the
     * `Acquisition_Deal_Actions` custom permission on the layer-5 `Acquisition_Deal_Driver` set,
     * and holding that permission does NOT imply holding `DPEG_Acquisition_Edit` — they are
     * different layers and different assignments (ARCHITECTURE.md §2, Permission Set Architecture).
     * `DPEG_Acquisition_Edit` DOES grant `Offering__c` create/edit/read + `viewAllRecords`, so the
     * grant exists — it simply does not cover the whole executing population.
     *
     * ═══ 🔴 ▸ SHARING = `without sharing`, VIA THE INNER CLASS — AND HERE THIS IS THE DANGEROUS
     *         HALF ═══
     * `SYSTEM_MODE` lifts CRUD and FLS and **NEVER** sharing. Measured against this repo
     * 2026-08-16: `Offering__c` is `sharingModel = Private` and `enableSharing = true`, and
     * `sharingRules/Offering__c.sharingRules-meta.xml` holds **exactly ONE rule** —
     * `Offering_IR_Visibility`, a **`sharingOwnerRules`** entry sharing rows owned by
     * `roleAndSubordinates Acquisitions_Analyst` to the **`Investor_Relations` group** with Edit.
     *
     * 🔴 **THAT RULE DOES NOTHING FOR THIS READ, AND THE DISTINCTION IS THE WHOLE POINT.** It
     * exists to make the shell visible to IR (Gate 1 Q1.2(b)); it shares TO Investor_Relations and
     * FROM the acquisitions role branch, so it grants the EXECUTING principal nothing they did not
     * already have. Under `with sharing` a principal who does not OWN an existing Offering and
     * holds no `viewAllRecords` grant still reads **zero rows** — and that is a live shape, not a
     * hypothetical one: user A executes a PSA and owns the shell, user B later re-executes the
     * same PSA. ⚠ Do not read "there is a sharing rule now" as "the sharing question is closed";
     * read WHO it shares to.
     *
     * For an IDEMPOTENCY GUARD a filtered read does not disable the feature — it **INVERTS** it:
     * zero rows means "no Offering exists", so the service creates a **DUPLICATE**, silently, with
     * both rows carrying an auto-numbered Name and nothing to say which is real. ARCHITECTURE.md §2
     * records this escalation verbatim: *"whenever a SYSTEM_MODE automation read against a
     * Private-OWD object is used to decide whether something already exists, sharing is not a
     * robustness question, it is a correctness one."* Same failure mode, and the same remedy, as
     * `PropertyAssetSelector.AssetCreationReads`.
     *
     * BULK read (`Set<Id>`): called ONCE per trigger chunk regardless of deal count. Never call it
     * per record.
     *
     * @param opportunityIds Opportunity Ids whose Offerings to look for (bound with IN);
     *                       null/empty-safe.
     * @return `Offering__c` rows with Id and `Opportunity__c` populated, one row per EXISTING
     *         Offering (a deal with two Offerings returns two); an empty list when the input is
     *         null/empty or no deal has one yet. Never null.
     * @example
     * Set&lt;Id&gt; alreadyHasOffering = new Set&lt;Id&gt;();
     * for (Offering__c o : OfferingSelector.selectByOpportunityIds(executedOppIds)) {
     *     alreadyHasOffering.add(o.Opportunity__c);
     * }
     */
    public static List<Offering__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Offering__c>();
        }
        return new ExecutionHandoffReads().byOpportunityIds(opportunityIds);
    }

    /**
     * 🔴 THE PSA-EXECUTION IDEMPOTENCY GUARD'S READ, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * It exists as its own class rather than as a keyword on `OfferingSelector` for one reason: a
     * `without sharing` outer class would silently widen every read added here later, including
     * ones that legitimately belong to a human. The escape is scoped to exactly one query, exactly
     * as `PropertyAssetSelector.AssetCreationReads`, `PropertySelector.FolderCreationReads` and
     * `InboundEmailStagingSelector.RoutingReads` are.
     *
     * The full argument — Private OWD, the one sharing rule that shares to IR and therefore does
     * nothing for THIS read, and why a filtered read here produces a DUPLICATE rather than a
     * silence — is on `selectByOpportunityIds`. Read it before changing this keyword.
     */
    private without sharing class ExecutionHandoffReads {

        /**
         * Existing Offerings for a set of Opportunities, read without sharing.
         *
         * @param opportunityIds The deals to check; never null/empty (the wrapper guards it).
         * @return One row per existing Offering; empty when none of the deals has one.
         */
        private List<Offering__c> byOpportunityIds(Set<Id> opportunityIds) {
            return [
                SELECT Id, Opportunity__c
                FROM Offering__c
                WHERE Opportunity__c IN :opportunityIds
                WITH SYSTEM_MODE
            ];
        }
    }
}
