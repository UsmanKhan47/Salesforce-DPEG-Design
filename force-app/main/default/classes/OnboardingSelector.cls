/**
 * Selector for Onboarding__c. Encapsulates ALL SOQL against Onboarding__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 (Onboarding + Task-rollup cleanup wave). This closes single-selector
 * ownership of Onboarding__c: the one inline query previously lived in
 * OnboardingController.activeOnboardings() and fed all five dashboard readers
 * (getKpis / getOnboardings / getPortfolio / getRiskAlerts / getTimeSla). Those
 * five now share a single selector call.
 *
 * ⚠ MODE IS A PROPERTY OF THE METHOD, NOT OF THE CLASS. READ THE METHOD.
 *
 * `selectActive()` uses `WITH USER_MODE` (API 67). Onboarding__c is a custom
 * object; P3 measured the custom-field FLS gap = 0, so USER_MODE is safe there and
 * enforces the running user's sharing + FLS. NOTE this was a deliberate behaviour
 * change: the relocated query ran in the default SYSTEM mode before (no WITH
 * clause); moving SOQL into the selector layer is the point at which USER_MODE is
 * applied, per the P4 goal. The internal PM dashboard personas that call these
 * AuraEnabled controllers hold the deployed Onboarding permsets, so USER_MODE
 * returns rows.
 *
 * ⚠ AMENDED 2026-08-22 (PM onboarding checklist fan-out + auto-create). This
 * header previously asserted, as a verified fact, "There is NO guest/automation
 * path on Onboarding__c, so NO `SYSTEM_MODE` appears here." THAT SENTENCE IS NOW
 * FALSE and is corrected here rather than left to mislead. Two automation paths
 * were added in that change and each brought a `WITH SYSTEM_MODE` read:
 *
 *   • selectByIdsForFanout      <- OnboardingFanoutService.fanOutNow, running
 *     inside OnboardingFanoutQueueable (async, no interactive user).
 *   • selectByPropertyAssetIds  <- OnboardingAutoCreateService, running inside the
 *     Property_Asset__c after-insert/after-update trigger, which itself fires
 *     inside an Opportunity Closed Won save driven by a Transactions persona.
 *
 * 🔴 BOTH ALSO ESCAPE SHARING, WHICH IS A SEPARATE DECISION FROM THE MODE — see
 * the `IdempotencyReads` inner class. Onboarding__c is Private OWD and BOTH reads
 * back IDEMPOTENCY GUARDS, where a sharing-filtered read does not disable the
 * feature, it INVERTS it into a duplicate-maker.
 *
 * ⚠ CLAUSE ORDER: `WITH USER_MODE` sits after the WHERE and BEFORE ORDER BY — the
 * order the P4 pilot flagged as a compile-breaker if reversed.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (P4 pilot template)
 * @see force-app/main/default/classes/TaskSelector.cls (sibling selector, this wave)
 * @see agent-output/p4-selector-design.md (§2, §4, §5)
 */
public with sharing class OnboardingSelector {

    /**
     * Terminal onboarding stage. An Onboarding__c in this stage is complete and is
     * excluded from every "active" dashboard read. Held here (not in the caller)
     * because the active/terminal split is a property of the query shape this
     * selector owns.
     */
    private static final String DONE_STAGE = 'Onboarding Complete';

    /**
     * All in-flight (non-terminal) Onboarding__c records for the PM dashboard,
     * ordered by target completion date (nulls last). Backs
     * OnboardingController's getKpis / getOnboardings / getPortfolio /
     * getRiskAlerts / getTimeSla — every field selected is read by at least one of
     * those five, so the field list is the union they need and must not be
     * narrowed without checking all five consumers.
     *
     * @return Active Onboarding__c records (Stage__c != 'Onboarding Complete')
     *         ordered by Target_Completion_Date__c NULLS LAST; an empty list when
     *         none are active (never null).
     * @example
     * List<Onboarding__c> active = OnboardingSelector.selectActive();
     */
    public static List<Onboarding__c> selectActive() {
        return [
            SELECT Id, Name, Property_Name__c, Stage__c, Status__c,
                   Start_Date__c, Target_Completion_Date__c, Onboarding_Lead__c,
                   Completion_Pct__c, Tasks_Total__c, Tasks_Complete__c, Tasks_In_Progress__c,
                   Tasks_Not_Started__c, Tasks_Blocked__c, Tasks_NA__c, Tasks_Open__c,
                   Tasks_Overdue__c, Tasks_Blocked_Now__c, Tasks_Stalled__c, Tasks_Due_7d__c,
                   Days_To_Onboard__c, Age_Days__c, Oldest_Open_Days__c, Is_Past_Target__c
            FROM Onboarding__c
            WHERE Stage__c != :DONE_STAGE
            WITH USER_MODE
            ORDER BY Target_Completion_Date__c NULLS LAST
        ];
    }

    /**
     * The minimum an Onboarding__c must carry for the checklist fan-out: its owner
     * (the fanned-out Tasks inherit it), its Start_Date__c (the base every due date
     * is offset from) and its Tasks_Fanned_Out__c marker (the idempotency guard).
     *
     * 🔴 THIS IS THE IDEMPOTENCY READ. `Tasks_Fanned_Out__c` is the ONLY thing
     * standing between one checklist and forty-five duplicate Tasks per re-save,
     * which is why both the mode AND the sharing context below are argued
     * separately rather than inherited.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION-PATH read (ARCHITECTURE.md §2). It runs inside
     * OnboardingFanoutQueueable, i.e. asynchronously, on behalf of whoever saved the
     * Onboarding rather than at their request. `WITH USER_MODE` does not degrade, it
     * THROWS: one ungranted field raises `System.QueryException: No such column`,
     * which in an async job means the checklist silently never appears and nothing
     * surfaces the reason. `Tasks_Fanned_Out__c` is a brand-new Metadata-API-deployed
     * field, and such a field arrives with NO FLS for any profile — System
     * Administrator included — so a USER_MODE read here would fail for EVERYBODY
     * until a permission set caught up. That is not an edge case, it is the default
     * state of the field on the day it deploys.
     *
     * ⚠ The field list is deliberately minimal. This query runs on every Onboarding
     * fan-out, so each field added is another way for the checklist to fail to build.
     *
     * BULK read (Set&lt;Id&gt;): called ONCE per queueable chunk regardless of how many
     * Onboardings that chunk carries. Never call it per record.
     *
     * @param ids Onboarding__c Ids to load; null/empty-safe.
     * @return Map keyed by Onboarding Id with Id, OwnerId, Start_Date__c and
     *         Tasks_Fanned_Out__c populated; an EMPTY map when the input is
     *         null/empty or nothing matched (never null). An id that is absent from
     *         the result was deleted between enqueue and execution — normal for an
     *         async job, and the caller simply builds nothing for it.
     */
    public static Map<Id, Onboarding__c> selectByIdsForFanout(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) {
            return new Map<Id, Onboarding__c>();
        }
        return new Map<Id, Onboarding__c>(new IdempotencyReads().byIdsForFanout(ids));
    }

    /**
     * Every existing Onboarding__c for a set of Property Assets — the IDEMPOTENCY
     * GUARD behind `OnboardingAutoCreateService`, which must never mint a second
     * onboarding for a property asset that already has one.
     *
     * 🔴 THE KEY IS `Property_Asset__c` ALONE, WITH NO STATUS OR STAGE FILTER, AND
     * THAT IS THE DECISION RATHER THAN AN OMISSION. An asset whose onboarding is
     * already `Onboarding Complete` therefore gets NO second onboarding if its
     * Closing Date is re-stamped. That is correct: the checklist is a one-time
     * mobilisation record, and a second one would split the task history in two and
     * give the PM dashboard two rows for one property. It is the same key, for the
     * same reason, as `PropertyAssetSelector.selectByPropertyIds` one object up.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION-PATH read. It runs inside the `Property_Asset__c` after-insert /
     * after-update trigger, which fires inside an `Opportunity` Closed Won save
     * driven by a `DPEG_Transaction_Team` persona — a persona that (measured on this
     * repo for the sibling asset read) holds no Property Management grants at all.
     * A `USER_MODE` throw here would escape as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and roll back the deal close, which is
     * precisely the outcome D-ON-1 forbids.
     *
     * ⚠ The field list is deliberately minimal (Id + Property_Asset__c). The caller
     * uses the result ONLY as a set-membership test.
     *
     * @param assetIds Property_Asset__c Ids to check; null/empty-safe.
     * @return One row per EXISTING Onboarding (an asset with two returns two), with
     *         Id and Property_Asset__c populated; an empty list when the input is
     *         null/empty or no asset has one yet (never null).
     */
    public static List<Onboarding__c> selectByPropertyAssetIds(Set<Id> assetIds) {
        if (assetIds == null || assetIds.isEmpty()) {
            return new List<Onboarding__c>();
        }
        return new IdempotencyReads().byPropertyAssetIds(assetIds);
    }

    /**
     * 🔴 THE TWO IDEMPOTENCY READS, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * ═══ WHY — `WITH SYSTEM_MODE` IS NOT ENOUGH ═══
     * `SYSTEM_MODE` lifts FLS and CRUD only; it does NOT lift record sharing.
     * Measured against this repo:
     *   - `objects/Onboarding__c/Onboarding__c.object-meta.xml` -> `sharingModel = Private`.
     *   - `sharingRules/Onboarding__c.sharingRules-meta.xml` holds ONE criteria rule,
     *     sharing rows whose `Status__c != ''` to the `DPEG_Property_Mgmt_Team`
     *     public group ONLY.
     *
     * So under `with sharing`, the principal driving either automation — an async
     * job's context for the fan-out, a Transactions persona's Closed Won save for
     * the auto-create — sees NONE of the rows that already exist. And for an
     * idempotency guard that failure mode is not a silence, it is an INVERSION:
     *
     *   fan-out     : `Tasks_Fanned_Out__c` reads as absent -> 45 DUPLICATE Tasks,
     *                 again on every re-save, forever.
     *   auto-create : "no onboarding exists" -> a SECOND Onboarding__c for one asset.
     *
     * Both are strictly worse than the feature not running at all, which is why the
     * sharing question is asked here separately from the mode question and answered
     * in its own narrow scope.
     *
     * ═══ WHAT THIS DOES NOT WIDEN ═══
     * Four fields on the fan-out read and two on the auto-create read, consumed as
     * guard state inside one service method each. Neither result is returned to a
     * controller, an LWC or a Flow. `selectActive()` — the only user-facing read on
     * this object — is untouched and stays `with sharing` + `WITH USER_MODE`.
     *
     * ═══ PRECEDENT ═══
     * `PropertyAssetSelector.AssetCreationReads` solved the identical problem one
     * object up, for the identical reason, in the identical shape.
     *
     * ═══ SCOPE — AS NARROW AS APEX ALLOWS ═══
     * Inner classes do NOT inherit the outer class's sharing, so this is declared
     * explicitly and `OnboardingSelector` itself STAYS `with sharing`. It is
     * `private`, so the only way in is the two public static wrappers above.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance methods and
     * the `new IdempotencyReads()` at each call site.
     */
    private without sharing class IdempotencyReads {

        /**
         * Fan-out state for a set of Onboardings, read without sharing. See
         * `selectByIdsForFanout` for the mode justification and the enclosing class
         * for the sharing one.
         *
         * @param ids The Onboardings to load; never null/empty (the wrapper guards it).
         * @return One row per existing Onboarding; empty when none survived.
         */
        private List<Onboarding__c> byIdsForFanout(Set<Id> ids) {
            return [
                SELECT Id, OwnerId, Start_Date__c, Tasks_Fanned_Out__c
                FROM Onboarding__c
                WHERE Id IN :ids
                WITH SYSTEM_MODE
            ];
        }

        /**
         * Existing onboardings for a set of property assets, read without sharing.
         * See `selectByPropertyAssetIds` for the key choice and the mode
         * justification, and the enclosing class for the sharing one.
         *
         * @param assetIds The assets to check; never null/empty (the wrapper guards it).
         * @return One row per existing Onboarding; empty when no asset has one.
         */
        private List<Onboarding__c> byPropertyAssetIds(Set<Id> assetIds) {
            return [
                SELECT Id, Property_Asset__c
                FROM Onboarding__c
                WHERE Property_Asset__c IN :assetIds
                WITH SYSTEM_MODE
            ];
        }
    }
}
