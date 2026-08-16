/**
 * The IR handoff artifact: an `Offering__c` shell opened when an ACQUISITION PSA is executed
 * (FSD Tranche 1, Item 1 — FSD §9 Conversion 3).
 *
 * 🔴 NOTHING CREATED AN `Offering__c` BEFORE THIS CLASS. Verified repo-wide 2026-08-16: zero Apex
 * creators, zero Flow creators, and the object's only non-metadata reference was
 * `TestDataFactory.createOfferings`. So Investor Relations was notified at contract execution
 * ("PSA executed — IR phase begins") and handed nothing to work from. This class closes exactly
 * that gap and nothing else.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. 🔴 ACQUISITION-ONLY IS **STRUCTURAL**, NOT A GUARD — DO NOT ADD A RECORD-TYPE TEST
 * ═══════════════════════════════════════════════════════════════════════════
 * The single call site is inside `ContractExecutionService.stampOpportunities(Set<Id>)`, and that
 * set can only ever contain **non-null `Contract_Review__c.Opportunity__c` parents** — a sell-side
 * PSA carries `Disposition__c` and a null `Opportunity__c`, so it never reaches this method at all.
 * Acquisition-only therefore costs zero code and cannot drift.
 *
 * ⚠ AND THE DISCRIMINATOR IS THE PARENT LOOKUP, NEVER THE RECORD TYPE. That is what
 * `Contract_Review__c.Disposition__c`'s own field metadata mandates ("this lookup, NOT the record
 * type, is the discriminator anything outside the record page should test") and it is the only
 * discriminator that survives the record-type migration window, in which every row still sits on
 * Master. A record-type test would classify every row as neither side and silently do nothing.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 2. IDEMPOTENCY — ON `Opportunity__c` ALONE
 * ═══════════════════════════════════════════════════════════════════════════
 * One bulk read (`OfferingSelector.selectByOpportunityIds`), one `Set<Id>` of deals that already
 * have a shell, skip those. Re-executing a PSA is a genuine no-op: zero rows built, zero DML.
 * The same shape as `ContractExecutionService.openTransactionsOnAboutToClose`.
 *
 * 🔴 THE GUARD READ MUST ESCAPE SHARING AND DOES — see `OfferingSelector.ExecutionHandoffReads`.
 * `Offering__c` is `sharingModel = Private`, and its ONE sharing rule shares to the
 * `Investor_Relations` group (see §5) — so it grants the EXECUTING principal nothing. A
 * sharing-filtered guard read therefore still returns zero rows, which for an existence test does
 * not disable the feature, it INVERTS it into a duplicate-maker. Argued at the selector, where the
 * query is.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. 🔴 `allOrNone = false` — A DECIDED TRADE (Gate 1, Q1.1), AND THE REPO PRECEDENT CUTS BOTH WAYS
 * ═══════════════════════════════════════════════════════════════════════════
 * Both in-repo precedents are real and they point in opposite directions, so this is stated as the
 * decision it is rather than as a safety feature:
 *
 *   `ContractExecutionService.advanceDispositionsToClosing`  chose **false**, because "an
 *       all-or-none update would roll back THE PSA EXECUTION ITSELF … The legal state is the
 *       irreplaceable half."
 *   `PropertyAssetService.ensureOnClosedWon`                 chose **true**, deliberately, "because
 *       its silent absence WAS the bug" — which is, word for word, this feature's own situation.
 *
 * The deciding fact is which half is irreplaceable. An executed PSA is a legal event with a
 * counterparty; an Offering shell is three fields a human can key in thirty seconds. So a refused
 * insert must not cost the execution — `false` it is.
 *
 * ⚠ **STATE THE RESIDUAL PLAINLY: A FAILED INSERT LEAVES NO OFFERING AND NO SIGNAL.** There is no
 * sweeper for this object, no status field to park a failure on, and nothing re-examines a deal
 * whose PSA has already been executed. `Database.SaveResult` failures are debug-logged below so the
 * cause is findable, but a debug line is not a work queue. If the failure population ever proves
 * non-empty in practice, the remedy is a `Pending`-style status on the deal plus a sweeper (the
 * `DealFolderSweepBatch` shape) — take it THEN, with the population as evidence.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 4. DML MODE — `AccessLevel.SYSTEM_MODE`, AND THE REASON IS **NOT** THE `Transaction__c` ONE
 * ═══════════════════════════════════════════════════════════════════════════
 * `openTransactionsOnAboutToClose` uses SYSTEM_MODE because the deal driver has `Create = false` on
 * `Transaction__c` and a bare insert throws `System.TypeException` (measured). ⚠ THAT MEASUREMENT
 * DOES NOT TRANSFER: `DPEG_Acquisition_Edit` grants `Offering__c` `allowCreate = true`,
 * `allowEdit = true`, `allowRead = true`, `viewAllRecords = true` and `editable = true` FLS on all
 * three fields (measured 2026-08-16). The acquisitions persona CAN create an Offering.
 *
 * SYSTEM_MODE is used anyway, for two narrower and separately checked reasons:
 *   1. The persona that EXECUTES a PSA is defined by the `Acquisition_Deal_Actions` custom
 *      permission on the layer-5 `Acquisition_Deal_Driver` set. Holding that permission does not
 *      imply holding `DPEG_Acquisition_Edit` — different layers, different assignments
 *      (ARCHITECTURE.md §2, Permission Set Architecture). The measured grant does not cover the
 *      whole executing population.
 *   2. `DPEG_Admin_Access` carries a `<tabSettings>` entry for `Offering__c` and **no
 *      `objectPermissions` entry at all**, so a bare administrator has no CRUD on it from that set.
 * A user-mode insert would therefore throw `System.TypeException` for part of the executing
 * population — and a `TypeException` is not a `DmlException`, so `allOrNone = false` would not
 * catch it and the PSA execution would roll back after all, defeating §3.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 5. 🔴 `IR_Owner__c` IS LEFT NULL, AND THE CONSEQUENCE IS BIGGER THAN THE FIELD
 * ═══════════════════════════════════════════════════════════════════════════
 * `IR_Owner__c` is a **User** lookup. `Investor_Relations` is a public **GROUP**, and a group Id is
 * not a valid value for a User lookup, so it cannot simply be assigned. Nothing anywhere in the
 * schema names "the IR owner". Two alternatives were considered and rejected: picking an arbitrary
 * group member (non-deterministic, and wrong the moment membership changes), and a Custom Setting
 * holding a default User Id (custom-setting DATA is not deployable and a User Id is org-specific,
 * so the value would be silently null on every org but one).
 *
 * ⚠ SO THE SHELL IS CREATED WITH NO IR OWNER NAMED ON IT, and — because `Offering__c` is Private
 * OWD — its RECORD owner is simply whoever executed the PSA, i.e. an acquisitions persona.
 *
 * 🔴 **IR VISIBILITY IS THEREFORE NOT A PROPERTY OF THIS CLASS AT ALL, AND IT WAS CLOSED
 * SEPARATELY (Gate 1 Q1.2(b), 2026-08-16, admin work in the same PR).** Do not go looking for it
 * here. Three artifacts carry it, and all three are needed:
 *   - `DPEG_IR_Edit` — `Offering__c` `allowRead`/`allowEdit` + editable FLS on all three fields.
 *     `allowCreate` and `allowDelete` are deliberately FALSE, so IR cannot mint a shell and bypass
 *     the one-per-Opportunity idempotency this class enforces.
 *   - `DPEG_IR_View` — the read-only twin.
 *   - `sharingRules/Offering__c` → `Offering_IR_Visibility`, an OWNER rule sharing rows owned by
 *     `roleAndSubordinates Acquisitions_Analyst` to the `Investor_Relations` group. Object
 *     permissions alone grant no record access on a Private-OWD object; this rule is the other
 *     half. **Neither set carries `viewAllRecords`.**
 *
 * 🔴 **ITS RESIDUAL IS A REAL PATH AND IT LANDS ON THIS CLASS'S OUTPUT, SO IT IS RESTATED HERE:**
 * the rule is scoped to owners inside the `Acquisitions_Analyst` role branch, and the owner is
 * whoever was logged in when the PSA was marked Executed. **An Offering created by a principal, an
 * administrator running UAT or a data fix, or anyone in the `Investor_Relations_Manager` /
 * `Transactions_Coordinator` branches is NOT shared to IR** — silently, with no error and nothing
 * in the UI to flag it, which is indistinguishable from "no Offering was created for this deal".
 * That is a user decision, not an oversight; the full statement and the named remedy (an
 * always-true criteria rule) are in `sharingRules/Offering__c.sharingRules-meta.xml`'s own comment.
 *
 * ⚠ Post-deploy gate **G4** stands regardless: verify by opening an Offering **AS AN IR USER**,
 * never as an administrator (an administrator passes for an unrelated reason), and remember that
 * group and role membership are not deployable metadata — an empty `Investor_Relations` group
 * makes the rule grant nothing while looking correctly deployed.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 6. WHAT THIS CLASS DELIBERATELY DOES NOT DO
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ **NO NOTIFICATION.** IR is already notified at this exact moment, by the existing batched
 * `GroupNotifier.notify()` call in `stampOpportunities` ("PSA executed — contract signed, IR phase
 * begins"). A second one would be two bells for one event.
 *
 * ⚠ **NO `Opportunity.Primary_Offering__c` STAMP, AND DO NOT ADD ONE FOR SYMMETRY.**
 * `Primary_LOI__c`'s stamp is load-bearing only because `ApprovalAuditService` resolves its LOI
 * target through it and swallows its own failures; nothing resolves an Offering. The field does not
 * exist, the `Offerings` child relationship already gives the related list, and adding a parent
 * stamp would import the whole approval-lock / deferred-stamp analysis
 * (`LoiPrimaryStampQueueable`, `DispositionNdaStampQueueable`) for no benefit.
 * `DispositionStageEntryService`'s LOI and PSA blocks carry no parent stamp for the same reason.
 *
 * ⚠ **NOTHING ADVANCES `Status__c` PAST `Draft`.** `Offering__c` has no record page, no Path and no
 * lifecycle automation. Creating the shell is the FSD's ask; "the Offering never leaves Draft" is a
 * KNOWN, NAMED state of this tranche and not a defect in it.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2). Zero inline SOQL — the read goes to `OfferingSelector`. Budget:
 * **1 SOQL / at most 1 DML per call, CONSTANT in deal count.** No SOQL or DML in a loop. A call
 * where every deal already has a shell costs 1 SOQL and ZERO DML, which is what makes re-execution
 * free.
 *
 * @see OfferingSelector.cls            (the guard read, and the sharing argument)
 * @see ContractExecutionService.cls    (the only caller — inside `stampOpportunities`)
 * @see PropertyAssetService.cls        (the same handoff shape, and the OPPOSITE `allOrNone` choice)
 */
public with sharing class OfferingService {

    /**
     * The shell's starting status. 🔴 SET EXPLICITLY, NEVER INHERITED FROM THE PICKLIST'S OWN
     * `<default>true</default>`. `Offering__c.Status__c` does carry `Draft` as its default today,
     * but a creator that relies on a field default breaks SILENTLY the moment an admin moves the
     * default — the row inserts happily carrying the wrong value, and nothing errors. Naming it
     * here makes that an intentional edit to this file instead.
     */
    @TestVisible
    private static final String STATUS_DRAFT = 'Draft';

    /**
     * 🔴 `false` — a refused Offering insert must NOT roll back the PSA execution. Gate 1 decision
     * Q1.1; the full trade, both in-repo precedents and the residual are in the class header §3.
     *
     * ⚠ NOT `final`, and that is a TEST SEAM rather than an oversight: it is the only way to prove
     * that flipping it to `true` is a deliberate act with a visible consequence, and the only way a
     * test can pin the partial-success branch. Production never assigns it.
     */
    @TestVisible
    private static Boolean allOrNone = false;

    /** Offerings the last call actually inserted. In-transaction only; for tests and debugging. */
    @TestVisible
    private static Integer lastRunCreated = 0;
    /** Deals the last call skipped because a shell already existed — the idempotency count. */
    @TestVisible
    private static Integer lastRunSkipped = 0;
    /** Rows the last call could not insert. See the class header §3: there is NO sweeper. */
    @TestVisible
    private static Integer lastRunFailures = 0;

    /**
     * Open the IR Offering shell for every acquisition deal whose PSA just became `Executed`.
     *
     * IDEMPOTENT on `Opportunity__c` alone: a deal that already has an Offering never gets a
     * second, whatever that Offering's `Status__c` is. See the class header §2.
     *
     * ⚠ CALLED ONCE PER TRIGGER CHUNK, with the whole set. Never call it per record — the whole
     * budget claim (1 SOQL / ≤1 DML, constant in deal count) depends on it.
     *
     * @param executedOppIds Opportunities whose acquisition PSA just became `Executed`. Null/empty
     *                       safe, and null members are skipped. These are `Opportunity__c` parents
     *                       of executed `Contract_Review__c` rows, which is what makes the whole
     *                       operation acquisition-only (class header §1).
     */
    public static void ensureOnPsaExecuted(Set<Id> executedOppIds) {
        lastRunCreated = 0;
        lastRunSkipped = 0;
        lastRunFailures = 0;

        // RETURN EARLY. A chunk in which no acquisition PSA was executed — every ordinary
        // Contract Review save, and every disposition one — costs zero queries and zero DML.
        if (executedOppIds == null || executedOppIds.isEmpty()) {
            return;
        }

        // ONE bulk read for the whole set. The guard escapes sharing inside the selector; see
        // OfferingSelector.ExecutionHandoffReads for why that is a correctness requirement here
        // and not robustness.
        Set<Id> alreadyHasOffering = new Set<Id>();
        for (Offering__c existing : OfferingSelector.selectByOpportunityIds(executedOppIds)) {
            alreadyHasOffering.add(existing.Opportunity__c);
        }

        List<Offering__c> toInsert = new List<Offering__c>();
        for (Id opportunityId : executedOppIds) {
            if (opportunityId == null) {
                continue;
            }
            if (alreadyHasOffering.contains(opportunityId)) {
                lastRunSkipped++;
                continue;
            }
            toInsert.add(new Offering__c(
                Opportunity__c = opportunityId,
                // Explicit; never the picklist default. See STATUS_DRAFT.
                Status__c = STATUS_DRAFT
                // IR_Owner__c is deliberately left NULL — class header §5, and post-deploy gate G4.
            ));
        }
        if (toInsert.isEmpty()) {
            return;
        }

        // allOrNone = false + SYSTEM_MODE. Two separate decisions, headers §3 and §4; neither
        // covers the other's obstacle.
        List<Database.SaveResult> results =
            Database.insert(toInsert, allOrNone, AccessLevel.SYSTEM_MODE);
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                lastRunCreated++;
                continue;
            }
            lastRunFailures++;
            // 🔴 THIS DEBUG LINE IS THE ONLY SIGNAL A FAILURE PRODUCES. It is recorded here rather
            // than swallowed precisely because §3 accepts that there is no sweeper — if this line
            // ever appears in a live log, the remedy is the status-plus-sweeper design named in the
            // header, not a wider catch.
            String detail = result.getErrors().isEmpty()
                ? 'no error detail'
                : result.getErrors()[0].getStatusCode() + ': ' + result.getErrors()[0].getMessage();
            System.debug(LoggingLevel.ERROR,
                'OfferingService: the IR Offering shell could NOT be created for an executed PSA ('
                + detail + '). The PSA execution stands. Nothing will retry this — there is no '
                + 'sweeper for Offering__c; create the shell by hand.');
        }
    }
}
