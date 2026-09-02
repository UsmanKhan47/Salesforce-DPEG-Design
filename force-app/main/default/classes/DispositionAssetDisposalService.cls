/**
 * Conversion 6 (BA story 49): when a Disposition reaches `Sale Closes`, the building DPEG just sold
 * stops being part of the portfolio — `Property_Asset__c.Status__c` moves `Active` -> `Disposed`.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS IS NOT "ADD A STATUS WRITE". IT IS THE MISSING WRITER FOR A FILTER REGIME THAT HAS
 *    BEEN SHIPPED, CORRECT AND COMPLETELY INERT FOR WEEKS.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Measured against the repo on 2026-09-02: EIGHT `Property_Asset__c` reports on the Disposition
 * dashboard already carry `Property_Asset__c.Status__c equals Active` INSIDE their `<filter>` —
 * `Readiness_Mix` and `Readiness_Signal_By_Value_Avk` (BOTH readiness donuts), plus
 * `Portfolio_Sell_Readiness`, `Properties_by_Argus_Value`, `Properties_in_AUM`,
 * `Sell_Readiness_By_Type`, `Total_Argus_Value` and `Sell_Ready_Argus`. Not one of them has ever
 * excluded a single row, because until this class existed **nothing anywhere in the application
 * wrote `'Disposed'`** — `PropertyAssetService.createAssets` writes the literal `'Active'` and is
 * the object's only other status writer.
 *
 * ⚠ SO THE BLAST RADIUS OF THIS CLASS IS NOT "one field on one record". The first asset that
 * reaches `Disposed` simultaneously leaves eight dashboard reports, both Sell Meter queries
 * (see `PropertyAssetSelector`) and therefore the Sell Meter's band tiles and Portfolio Upside
 * figure. On the four-asset portfolio live in `usman-dpeg` that is a 25% change, visible the
 * instant it happens. It is the intent of story 49 and it was confirmed at Gate 1 on 2026-09-02
 * (decision G-2) — it is recorded here because "the number on the Home page moved" is the first
 * thing anyone will notice and the last thing they will connect to a disposition stage change.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 `Property_Asset__c` IS A SHARED OBJECT. SIXTEEN OTHER OBJECTS LOOK UP TO IT.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Enumerated on 2026-09-02 by grepping every field-meta file under `objects` for a
 * `Property_Asset__c` lookup — every object that carries one, and what a `Disposed` parent means
 * for each:
 *
 * ⚠ THE GLOB THAT WOULD HAVE DESCRIBED THAT SWEEP IS DELIBERATELY NOT WRITTEN HERE. A path
 * containing a directory wildcard followed by a slash ENDS AN APEX BLOCK COMMENT — the two
 * characters are the comment terminator — and the compiler then reports a cascade of errors on
 * lines that have nothing to do with it. This repo has already paid for that once. Describe the
 * sweep in words, or put the pattern in a line comment.
 *
 *   Property Management  Onboarding__c, CAM_Reconciliation__c, Delinquency__c,
 *                        Insurance_Policy__c, Receivables_Summary__c, Vendor_Contract__c,
 *                        Meter__c, Unit__c, Work_Order__c, Case
 *   Leasing              Lease_Inquiry__c, Lease_Renewal__c, Broker_Assignment__c
 *   Dispositions         Disposition__c, BOV_Submission__c
 *   Acquisitions         Lead
 *
 * 🔴 NOTHING IN THAT LIST READS `Status__c` AS A GATE, AND THAT WAS CHECKED RATHER THAN ASSUMED.
 * A repo-wide grep for `Status__c` on this object returns exactly three production consumers:
 *   1. `PropertyAssetService.createAssets` — WRITES the literal `'Active'` on creation;
 *   2. `PropertyAssetSelector.selectByPropertyIds` — deliberately has NO status filter, so a
 *      re-acquired property reuses its EXISTING asset rather than minting a rival (D27.3). That
 *      contract is UNCHANGED by this class and must stay that way: re-acquisition is expressed
 *      by moving the asset BACK to `Active`, not by a second row;
 *   3. `OnboardingAutoCreateService` — names `Status__c` only to explain why it does NOT use it
 *      (it keys on `Closing_Date__c`, because `Status__c` reads `Active` from birth).
 * Every other hit is a DIFFERENT object's own `Status__c` (`Broker_Assignment__c.Status__c`,
 * `Onboarding__c.Status__c`) reached through a `Property_Asset__c` column in the same SELECT.
 * ⇒ No PM, Leasing or Work Order behaviour changes when an asset is marked `Disposed`. Their
 * records stay attached to the same asset, which is what makes the history survive the sale.
 *
 * ✅ AND PM DOES NOT LOSE ACCESS — THIS IS THE ONE THAT LOOKED DANGEROUS AND IS NOT.
 * `sharingRules/Property_Asset__c.sharingRules-meta.xml` holds ONE criteria rule,
 * `Property_Asset_PM_All_RW`: `Status__c notEqual ''` -> `DPEG_Property_Mgmt_Team`, access Edit.
 * The criterion is "status is NOT BLANK", not "status is Active". `'Disposed'` is not blank, so a
 * disposed asset REMAINS shared Edit with the Property Management team and every PM child record
 * stays reachable. ⚠ The dangerous value here is BLANK, not `Disposed` —
 * `PropertyAssetService.cls:191-196` already records that a blank status would hide the asset from
 * PM entirely. Nothing in this class can produce a blank.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHICH WRITE PATH — TRIGGER, DELIBERATELY, AND NOT THE THREE ALTERNATIVES
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `Sale Closes` is reached by exactly two mechanisms, and a writer that covers only one is a
 * writer that silently does nothing half the time:
 *   (i)  `DispositionApprovalAdvanceQueueable` -> `DispositionApprovalAdvanceService.advance`,
 *        which maps `<recordType>|Closing => 'Sale Closes'` for BOTH record types on final
 *        approval of `Closing_Approval`;
 *   (ii) a direct edit of `Disposition_Stage__c` by an admin or a data load.
 * An `after update` hook on `DispositionTrigger` sees both, because (i) is an ordinary
 * `Database.update` that re-fires this trigger (the Queueable's own header says so, and relies on
 * it for the NDA stage-entry case).
 *
 *   ❌ AN APPROVAL-TRIGGERED FLOW. Rejected for the reason `DispositionApprovalAdvanceService`'s
 *      header already records as a MEASURED org incident: a record-triggered flow with no
 *      `<runInMode>` runs as the APPROVER, its DML fails on that read-only persona's CRUD with a
 *      `TypeException` that escapes a `DmlException`-only fault path, AND ROLLS BACK THE APPROVAL
 *      ITSELF. That is the whole reason this module has a semaphore.
 *   ❌ AN APPROVAL `finalApprovalActions` FIELD UPDATE. A workflow field update cannot write a
 *      field on a PARENT-of-a-lookup at all, and even for the semaphore this module deliberately
 *      confines field updates to one FLS-less boolean.
 *   ❌ A ROLL-UP OR FORMULA. `Disposition__c.Property_Asset__c` is a Lookup, not Master-Detail
 *      (the same fact that forces `DispositionTractionService` to count offers in Apex), so no
 *      declarative aggregate can reach from the child stage to the parent status.
 *
 * ⚠ AND IT IS HUNG OFF `route(...)`, WHICH SERVES BOTH `afterInsert` AND `afterUpdate`. The insert
 * branch is very nearly unreachable in production and is wired anyway rather than guarded away:
 * `Wire_Complete_Before_Sale_Closes` fires on `OR(ISNEW(), ISCHANGED(Disposition_Stage__c))`, so a
 * row INSERTED at `Sale Closes` is refused unless `Wire_Verification_Completed__c` is already true
 * — which a brand-new record cannot be. If a future data load ever does arrive at that stage with
 * the flag set, the asset should still be disposed; treating an insert as an entry is also exactly
 * what `DispositionStageEntryService` does with the same `prior == null` convention, and the two
 * hooks disagreeing about what an insert means is a defect class this module has already paid for.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE READ **AND** THE WRITE ESCAPE SHARING, AND THEY ARE TWO SEPARATE DECISIONS
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * WHO RUNS THIS CODE on path (i): the APPROVER. The chain is `finalApprovalActions` sets the
 * semaphore -> `DispositionTrigger` -> `System.enqueueJob` -> the Queueable, and **a Queueable
 * executes as the ENQUEUING user**, which is whoever clicked Approve. The async hop moves the
 * approval LOCK problem and moves NOTHING about identity.
 *
 * `objects/Property_Asset__c/Property_Asset__c.object-meta.xml` -> `sharingModel = Private`, and
 * the one sharing rule on the object shares only to `DPEG_Property_Mgmt_Team`. A disposition
 * principal approving a closing is not in that group and does not own the asset.
 *
 * Per ARCHITECTURE.md §2: **`SYSTEM_MODE` bypasses CRUD/FLS ONLY — it does NOT bypass sharing.**
 * So `SYSTEM_MODE` alone is not sufficient here, and the two halves fail DIFFERENTLY:
 *   - a sharing-filtered READ returns no row, `updates` comes back empty, and the asset is
 *     SILENTLY NEVER DISPOSED. The idempotency guard would have inverted into a no-op — the exact
 *     shape `PropertyAssetSelector.AssetCreationReads` exists to prevent, pointing the other way;
 *   - a sharing-refused WRITE throws, which is loud.
 * Both therefore run in narrow `without sharing` scopes: the read in
 * `PropertyAssetSelector.selectStatusByIds` (`DisposalReads`), the write in `AssetDisposalWrites`
 * below. This class itself stays `with sharing` and holds no other statement that escapes it.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 `allOrNone = true`, AND THE CONSEQUENCE IS STATED RATHER THAN HIDDEN
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `Database.update(assets, true, AccessLevel.SYSTEM_MODE)`. A partial-success write here would
 * swallow precisely the sharing failure this class is shaped around — the failure would land in a
 * `SaveResult` nobody inspects, the disposition would advance, and the asset would stay on the
 * Sell Meter forever with no signal anywhere. `DispositionApprovalAdvanceService` can afford
 * `allOrNone = false` because a refused row leaves a STUCK SEMAPHORE that is queryable; there is
 * no equivalent durable marker for a lost status write.
 *
 * ⚠ WHAT THAT COSTS, PLAINLY: an exception here escapes the after-update trigger as
 * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and refuses the stage move to `Sale Closes` — on path (i)
 * that fails the whole Queueable execution and every semaphore in that chunk stays true (visible,
 * recoverable); on path (ii) the admin's own save is refused with a readable error. Both are loud.
 * The failure surface is deliberately near-empty: `Property_Asset__c` has NO validation rules
 * (`objects/Property_Asset__c/validationRules/` does not exist), `'Disposed'` is a live member of
 * a restricted two-value picklist, the object has NO record types, and both CRUD/FLS and sharing
 * are lifted at the statement. 🔴 DO NOT "SOFTEN" THIS TO `allOrNone = false` — that converts the
 * one loud failure mode into the silent one.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * IDEMPOTENCY, AND WHY IT IS TWO GUARDS RATHER THAN ONE
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 *   1. THE TRANSITION, NOT THE VALUE. A row already at `Sale Closes` that is saved again for any
 *      other reason is not an entry. This is the same convention `DispositionStageEntryService`
 *      and `DispositionApprovalAdvanceService.enqueuePendingAdvances` both use.
 *   2. THE STATUS RE-READ. Two dispositions can point at ONE asset (a portfolio sold in parts, or
 *      a re-listed building), so a second disposition transitioning later would re-write an asset
 *      that is already `Disposed`. Skipping it keeps the write count honest and — more usefully —
 *      keeps `PropertyAssetTrigger` from firing on a save that changes nothing.
 * Together they mean a re-save at `Sale Closes` costs ZERO queries and ZERO DML, and a genuine
 * entry on an already-disposed asset costs ONE query and ZERO DML.
 *
 * ⚠ THE CASCADE THIS WRITE FIRES IS PROVABLY INERT, AND IT IS STATED HERE SO NOBODY RE-DERIVES IT.
 * Writing `Status__c` fires `PropertyAssetTrigger (after insert, after update)` ->
 * `PropertyAssetTriggerHandler.afterUpdate`, whose two jobs are
 * `OnboardingAutoCreateService.ensureOnClosing` (returns before any SOQL unless `Closing_Date__c`
 * TRANSITIONS to non-null) and `BovAutoSelectionService.reselectForRepricedDispositions` (returns
 * before any SOQL unless `Target_Sale_Price__c` CHANGES). A `Status__c`-only shell carries neither
 * field, so neither job does anything. ⚠ It is a shell BY CONSTRUCTION for that reason — do not
 * "optimise" this into re-using the queried `Property_Asset__c` rows, which would carry
 * `Closing_Date__c`-shaped values into the old/new comparison of a service that reads them.
 *
 * ── LAYERING / BULK ─────────────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2). ZERO inline SOQL — the read goes to
 * `PropertyAssetSelector.selectStatusByIds`. Trigger-driven, so `.claude/rules/bulk-test-rule.md`'s
 * 251-record mandate applies in full with no exemption to claim. Budget is AT MOST one query and
 * one DML per trigger chunk, CONSTANT in the number of dispositions — that constancy, not "251
 * rows produced 251 writes", is the property `DispositionAssetDisposalServiceTest` asserts.
 *
 * @see force-app/main/default/classes/PropertyAssetSelector.cls (the read + its own sharing note)
 * @see force-app/main/default/classes/DispositionTriggerHandler.cls (the hook)
 * @see force-app/main/default/classes/DispositionApprovalAdvanceService.cls (write path (i))
 */
public with sharing class DispositionAssetDisposalService {

    /**
     * The terminal disposition stage. Case must match
     * `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` and BOTH record-type
     * subsets exactly — verified 2026-09-02: `Sale Closes` is present and active on `On_Market`
     * (11 stages) AND on `Off_Market` (9 stages), so this hook is record-type-agnostic and needs
     * no `DispositionDomain.recordTypeNameOf` key the way the advance map does.
     */
    @TestVisible
    private static final String STAGE_SALE_CLOSES = 'Sale Closes';

    /**
     * The value written. One of exactly two members of a RESTRICTED picklist
     * (`Active` default / `Disposed`), so DML enforces it — a typo here is a runtime refusal on a
     * disposition close, not a silent no-op. `Property_Asset__c` has NO record types, so there is
     * no per-type subset that could accept `Disposed` on one type and refuse it on another.
     */
    @TestVisible
    private static final String STATUS_DISPOSED = 'Disposed';

    /**
     * AFTER INSERT / AFTER UPDATE. Marks the parent Property Asset of every disposition that just
     * TRANSITIONED INTO `Sale Closes` as `Disposed`.
     *
     * @param newDispositions Trigger.new; null/empty-safe.
     * @param priorById       Trigger.oldMap on update; null on insert (see the class header on why
     *                        an insert counts as an entry).
     */
    public static void markAssetsDisposed(
        List<Disposition__c> newDispositions,
        Map<Id, Disposition__c> priorById
    ) {
        if (newDispositions == null || newDispositions.isEmpty()) {
            return;
        }

        // A Set, so two dispositions closing on the SAME asset in one chunk produce one row.
        Set<Id> assetIds = new Set<Id>();
        for (Disposition__c d : newDispositions) {
            if (d.Property_Asset__c == null) {
                // Unreachable in production — `Property_Asset_Required_On_Save` refuses it — but a
                // null here would be a NullPointerException inside a trigger, so it is guarded
                // rather than asserted.
                continue;
            }
            if (d.Disposition_Stage__c != STAGE_SALE_CLOSES) {
                continue;
            }
            Disposition__c prior = (priorById == null) ? null : priorById.get(d.Id);
            if (prior != null && prior.Disposition_Stage__c == STAGE_SALE_CLOSES) {
                // Already there before this save — a re-save, not an entry.
                continue;
            }
            assetIds.add(d.Property_Asset__c);
        }

        // RETURN EARLY, BEFORE THE SELECTOR. This is what makes the overwhelmingly common
        // Disposition save — any save that does not enter `Sale Closes` — cost zero queries and
        // zero DML on this trigger.
        if (assetIds.isEmpty()) {
            return;
        }

        List<Property_Asset__c> updates = new List<Property_Asset__c>();
        // ⚠ ONE LINE, DELIBERATELY. Never wrap a STATIC call between the class name and the dot:
        // `PropertyAssetSelector` followed by a line break and `.selectStatusByIds(...)` compiles
        // the class name as a VARIABLE and fails the deploy with "Variable does not exist:
        // PropertyAssetSelector" — an error that names the class and reads exactly like a missing
        // component. This repo has shipped that shape twice.
        for (Property_Asset__c a : PropertyAssetSelector.selectStatusByIds(assetIds)) {
            if (STATUS_DISPOSED.equalsIgnoreCase(a.Status__c)) {
                continue; // already disposed — nothing to write, and no PropertyAssetTrigger firing
            }
            // A SHELL, not the queried row. See the cascade note in the class header: re-using the
            // queried record would carry other fields into PropertyAssetTriggerHandler's
            // old-vs-new comparisons.
            updates.add(new Property_Asset__c(Id = a.Id, Status__c = STATUS_DISPOSED));
        }
        if (updates.isEmpty()) {
            return;
        }
        new AssetDisposalWrites().apply(updates);
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ONE STATEMENT THAT ESCAPES SHARING, AND WHY IT HAS TO.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * The full argument is in the class header; the short form, kept AT the declaration because
     * that is where ARCHITECTURE.md §2 requires it:
     *
     *   WHO RUNS IT      the `Closing_Approval` approver (a Queueable runs as its enqueuer), or an
     *                    admin editing the stage directly.
     *   WHAT IT TOUCHES  `Property_Asset__c`, `sharingModel = Private`, shared by exactly one
     *                    criteria rule to `DPEG_Property_Mgmt_Team` — a group a disposition
     *                    principal is not in, on a record they do not own.
     *   WHY SYSTEM_MODE  IS NOT ENOUGH — it lifts CRUD and FLS and NEVER record sharing
     *                    (ARCHITECTURE.md §2). Both are needed and they are two decisions.
     *   HOW NARROW       one `Database.update` over a list the caller built from Ids that came out
     *                    of the trigger context, holding one field. This class stays
     *                    `with sharing`; inner classes do not inherit it, so this is declared
     *                    explicitly. `private`, so the only way in is `markAssetsDisposed`.
     *
     * PRECEDENT: `DispositionApprovalAdvanceService.SemaphoreAdvanceWrites` (the same approver, the
     * same transaction, the sibling record) and `PropertyAssetSelector.AssetCreationReads`.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new AssetDisposalWrites()` at the call site.
     */
    private without sharing class AssetDisposalWrites {
        /**
         * @param updates One-field `Property_Asset__c` shells; never null, never empty.
         * @return The save results, unused — `allOrNone = true` means a failure has already thrown
         *         by the time this returns. The return type is kept so a future caller that wants
         *         to inspect them does not have to change the signature; see the class header on
         *         why `allOrNone = false` must not be introduced here.
         */
        private List<Database.SaveResult> apply(List<Property_Asset__c> updates) {
            return Database.update(updates, true, AccessLevel.SYSTEM_MODE);
        }
    }
}
