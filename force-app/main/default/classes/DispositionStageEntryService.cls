/**
 * Creates a Disposition's stage-entry child records — the disposition twin of
 * OpportunityReviewService, and deliberately shaped after it rather than invented fresh
 * (decisions D15/Q3, D16.2, D19.1).
 *
 * IT DOES THREE THINGS, ONE PER STAGE, AND THE THREE ARE NOT INTERCHANGEABLE:
 *
 *   | stage entered | child opened                        | added   | DML mode    | parent stamp |
 *   | ------------- | ----------------------------------- | ------- | ----------- | ------------ |
 *   | `NDA`         | NDA__c, Party_Role__c = 'Buyer'     | 3A      | SYSTEM_MODE | DEFERRED     |
 *   | `LOI`         | LOI__c, Disposition_LOI             | 3B fix  | SYSTEM_MODE | NONE         |
 *   | `PSA`         | Contract_Review__c, Disposition_PSA | 3C fix  | SYSTEM_MODE | NONE         |
 *
 * 🔴 THE LAST TWO COLUMNS ARE THE PART A READER MUST NOT SKIM. All three blocks use SYSTEM_MODE
 * DML, but ONLY the NDA block defers a parent stamp to a Queueable, and the reason is NOT that the
 * other two were simplified — it is that they have nothing to defer. Each block's reasoning is
 * argued at the block, from scratch, because inheriting a justification is precisely the mistake
 * review W1 caught in DispositionNdaStampQueueable (which had copied
 * OpportunityReviewService's LOI-block wording verbatim into a case where it did not hold).
 *
 * ── 🔴 IT FIRES ON A RECORD THAT THREE APPROVALS LOCK ────────────────────────
 * `Disposition__c` is the entry object of `Sale_Decision_Approval` (at Disposition Readiness),
 * `Broker_Selection_Approval` (at BOV Outreach) and `Closing_Approval` (at Closing). All three
 * declare `recordEditability = AdminOnly`, so while any of them is pending the record is LOCKED.
 *
 * ⚠ THE LOCK BITES A PARENT WRITE, NOT A CHILD INSERT. `SYSTEM_MODE` lifts CRUD and FLS but does
 * NOT lift an approval lock (measured on the LOI path; see LoiPrimaryStampQueueable's header for
 * the two failed attempts). A child of a locked record is not itself locked, so every child insert
 * below is safe synchronously; a write BACK to `Disposition__c` is not. That single distinction is
 * what makes the NDA block's Queueable necessary and the other two blocks' absence of one correct.
 *
 * ⚠ And note the asymmetry OpportunityReviewService records: FIVE of its six child-creation blocks
 * deliberately use neither SYSTEM_MODE nor a deferred stamp, because a deal driver with Edit enters
 * those stages. Do not harmonize in either direction.
 *
 * ── LAYERING / BULK ─────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2). ZERO inline SOQL — the three idempotency reads go to
 * NdaSelector.selectByDispositionIds, LoiSelector.selectByDispositionIds and
 * ContractReviewSelector.selectByDispositionIds, all `WITH SYSTEM_MODE` for automation-path reasons
 * documented at those methods.
 *
 * Trigger-driven, so the `.claude/rules/bulk-test-rule.md` per-transaction-singleton exemption
 * does NOT apply and literal 251-record bulk tests exist for all three stages. Budget is
 * 1 SOQL / 1 DML PER STAGE ENTERED IN THE CHUNK (≤ 3 / ≤ 3), plus ≤ 1 enqueue for the NDA block —
 * CONSTANT IN THE NUMBER OF DISPOSITIONS. That constancy is the property the bulk tests assert,
 * not merely that 251 rows produced 251 children. A chunk that enters no target stage at all — the
 * overwhelmingly common case, since this trigger now fires on EVERY Disposition write in the org —
 * costs zero queries, zero DML and zero enqueues.
 *
 * @see force-app/main/default/classes/OpportunityReviewService.cls (the acquisitions twin)
 * @see force-app/main/default/classes/DispositionNdaStampQueueable.cls (the deferred NDA stamp)
 * @see force-app/main/default/classes/NdaSelector.cls (the NDA idempotency read)
 * @see force-app/main/default/classes/LoiSelector.cls (the LOI idempotency read)
 * @see force-app/main/default/classes/ContractReviewSelector.cls (the PSA idempotency read)
 */
public with sharing class DispositionStageEntryService {

    /** The stage whose ENTRY opens the buyer's NDA. Off-market only by value set (D5). */
    @TestVisible
    private static final String NDA_STAGE = 'NDA';

    /**
     * The stage whose ENTRY opens the sell-side LOI.
     *
     * ⚠ UNLIKE `NDA`, THIS STAGE IS ON BOTH DISPOSITION RECORD TYPES — verified against
     * objects/Disposition__c/recordTypes/: `LOI` and `PSA` are exposed on `On_Market` AND
     * `Off_Market`, while `NDA` is off-market only. So these two blocks fire for a broker-listed
     * sale as well as a direct one, and that is correct: an on-market disposition negotiates an LOI
     * exactly as an off-market one does. A future change that scoped either block to a record type
     * would silently strip the negotiation record from every broker-listed sale.
     */
    @TestVisible
    private static final String LOI_STAGE = 'LOI';

    /** The stage whose ENTRY opens the sell-side PSA. On BOTH record types — see LOI_STAGE. */
    @TestVisible
    private static final String PSA_STAGE = 'PSA';

    /**
     * Developer name of the record type every auto-created DISPOSITION NDA is stamped with.
     * Case must match objects/NDA__c/recordTypes/ exactly — getRecordTypeInfosByDeveloperName()
     * keys its map case-SENSITIVELY.
     */
    @TestVisible
    private static final String DISPOSITION_NDA_RECORD_TYPE = 'Disposition_NDA';

    /** Ditto, objects/LOI__c/recordTypes/. */
    @TestVisible
    private static final String DISPOSITION_LOI_RECORD_TYPE = 'Disposition_LOI';

    /** Ditto, objects/Contract_Review__c/recordTypes/. */
    @TestVisible
    private static final String DISPOSITION_PSA_RECORD_TYPE = 'Disposition_PSA';

    /**
     * The counterparty role the auto-created NDA carries, and simultaneously the NDA block's
     * IDEMPOTENCY KEY (D19.1). Changing this constant silently changes both.
     */
    @TestVisible
    private static final String BUYER_ROLE = 'Buyer';

    /**
     * Disposition_NDA's default Status__c.
     *
     * ⚠ IT IS A CONSTANT AND HAS TO BE. Apex describes expose a picklist's FIELD-level default,
     * not a RECORD-TYPE-level one, so "the record type's default" is not readable from Apex at
     * any price — and record-type picklist restriction is UI-only, so DML would happily accept
     * 'Pending' here and produce an NDA whose status is off its own value set. Keep this in step
     * with the `<default>true</default>` entry under Status__c in
     * objects/NDA__c/recordTypes/Disposition_NDA.recordType-meta.xml.
     */
    @TestVisible
    private static final String DISPOSITION_NDA_INITIAL_STATUS = 'Not Sent';

    /**
     * Disposition_LOI's default Stage__c. Same "constants, not describes" reasoning as
     * DISPOSITION_NDA_INITIAL_STATUS — keep in step with the `<default>true</default>` entry under
     * Stage__c in objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml.
     *
     * 🔴 'Draft' — the FIELD-level default and the acquisition starting stage — WOULD INSERT
     * HAPPILY HERE and produce an LOI whose stage is off its own record type's value set. The two
     * LOI value sets are fully DISJOINT (D6), so RecordStageAdvanceService's disposition sequence
     * has no 'Draft' entry at all and the row could never be advanced. Nothing but this constant
     * prevents that.
     */
    @TestVisible
    private static final String DISPOSITION_LOI_INITIAL_STAGE = 'Received';

    /**
     * Disposition_PSA's default Negotiation_Status__c.
     *
     * 🔴 IT IS Negotiation_Status__c AND NOT Stage__c, AND THAT IS NOT A STYLE CHOICE. On
     * `Contract_Review__c`, `Stage__c` is a DERIVED PROJECTION: the active before-save flow
     * `Contract_Review_Stage_Sync` recomputes it from `Negotiation_Status__c` on every create and
     * update, so a direct write to `Stage__c` COMMITS AND IS SILENTLY DISCARDED (measured
     * 2026-08-05 on CTR-0000; the full note is at
     * ContractReviewSelector.selectStageRequiredById). Seeding `Stage__c` here would therefore look
     * like it worked and mean nothing. Setting the status is what actually produces
     * `Stage__c = 'PSA Drafting'`.
     *
     * ⚠ This value happens to equal the field-level default too, so leaving it unset would produce
     * the same row TODAY. It is set explicitly anyway: the value is a business decision of this
     * feature (a new sell-side PSA opens at its first draft), and an implicit default is not
     * falsifiable by a test. Keep in step with the `<default>true</default>` entry under
     * Negotiation_Status__c in
     * objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml.
     */
    @TestVisible
    private static final String DISPOSITION_PSA_INITIAL_STATUS = 'Initial Draft';

    /**
     * Called from the Disposition__c after-insert / after-update trigger. Opens each stage's child
     * record on ENTRY to that stage, exactly once per disposition.
     *
     * @param newDispositions Trigger.new
     * @param oldMap          Trigger.oldMap on update; null on insert (an insert is treated as
     *                        entry into whatever stage the row was created at)
     */
    public static void createStageEntryRecords(
        List<Disposition__c> newDispositions,
        Map<Id, Disposition__c> oldMap
    ) {
        Set<Id> ndaStageEntrants = new Set<Id>();
        Set<Id> loiStageEntrants = new Set<Id>();
        Set<Id> psaStageEntrants = new Set<Id>();
        for (Disposition__c d : newDispositions) {
            Disposition__c prior = (oldMap == null) ? null : oldMap.get(d.Id);
            String priorStage = (prior == null) ? null : prior.Disposition_Stage__c;
            // ENTRY, not presence. An update that leaves the stage alone must not re-open a child
            // — which is what makes the deferred parent stamp's own update a no-op here.
            if (priorStage == d.Disposition_Stage__c) {
                continue;
            }
            if (NDA_STAGE == d.Disposition_Stage__c) {
                ndaStageEntrants.add(d.Id);
            } else if (LOI_STAGE == d.Disposition_Stage__c) {
                loiStageEntrants.add(d.Id);
            } else if (PSA_STAGE == d.Disposition_Stage__c) {
                psaStageEntrants.add(d.Id);
            }
        }
        // Each helper returns immediately on an empty set, so a chunk that entered none of the
        // three target stages — the overwhelmingly common Disposition save — costs nothing at all.
        openBuyerNdas(ndaStageEntrants);
        openDispositionLois(loiStageEntrants);
        openDispositionContractReviews(psaStageEntrants);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // `NDA` STAGE — the buyer's NDA. Tranche 3A.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Opens one buyer NDA per entrant, then defers the parent stamp.
     *
     * ── IDEMPOTENCY: THE KEY IS Party_Role__c = 'Buyer', NOT "any NDA" ───────
     * D19.1: auto-create makes the BUYER NDA only. A broker NDA is added by hand from the related
     * list when a broker actually introduced the buyer — something the system cannot know in
     * advance. So "already has an NDA" is the WRONG suppression test: a user who added the broker's
     * NDA early would then never get the buyer's. The key is "already has a BUYER NDA on this
     * disposition", which is also what makes re-entering the stage, a re-save, and the stamp update
     * itself all no-ops.
     *
     * ⚠ THIS IS THE ONE BLOCK WHOSE IDEMPOTENCY KEY IS NOT SIMPLE PRESENCE. The LOI and PSA blocks
     * have no Party_Role__c equivalent — there is exactly one kind of disposition LOI and one kind
     * of disposition PSA — so for them "already has one" IS the whole test. Do not "harmonize" this
     * one down to presence.
     *
     * ⚠ The check is deliberately NOT scoped to the Disposition_NDA record type. In the window
     * between the record-type deploy and post-deploy gate T-A1, a buyer NDA can legitimately sit on
     * MASTER — and suppressing on record type would then mint a second one.
     */
    private static void openBuyerNdas(Set<Id> entrants) {
        if (entrants.isEmpty()) {
            return;
        }
        // One query for the whole chunk — never one per record.
        for (NDA__c existing : NdaSelector.selectByDispositionIds(entrants)) {
            if (BUYER_ROLE.equals(existing.Party_Role__c)) {
                entrants.remove(existing.Disposition__c);
            }
        }
        if (entrants.isEmpty()) {
            return;
        }

        // Resolved ONCE for the whole chunk — a describe per record would be 251 describes for an
        // answer that cannot vary within a transaction.
        Id recordTypeId = recordTypeIdFor(NDA__c.SObjectType, DISPOSITION_NDA_RECORD_TYPE);
        List<NDA__c> toInsert = new List<NDA__c>();
        for (Id dispositionId : entrants) {
            NDA__c nda = new NDA__c(
                Disposition__c = dispositionId,
                Status__c = DISPOSITION_NDA_INITIAL_STATUS,
                Party_Role__c = BUYER_ROLE
            );
            if (recordTypeId != null) {
                nda.RecordTypeId = recordTypeId;
            }
            toInsert.add(nda);
        }

        // ⚠ EXPLICIT SYSTEM MODE — obstacle 1 of 2 for THIS block. The disposition persona holds
        // allowEdit and NOT allowCreate on NDA__c by decision D16.1, and the running user may
        // additionally be an APPROVER who is read-only on both objects. NDA__c is not the record
        // under approval, so it is not locked and inserts fine here; the user sees the NDA
        // immediately.
        //
        // allOrNone = true, matching the LOI block in OpportunityReviewService. The trade is
        // deliberate: if the NDA cannot be created, the stage change that was supposed to open it
        // is rolled back rather than leaving an off-market disposition sitting at `NDA` with
        // nothing to sign — a state the All_NDAs_Signed_Before_Progression gate would then read as
        // "no NDAs collected" and block on anyway, but silently and one stage later.
        Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);

        Map<Id, Id> ndaByDisposition = new Map<Id, Id>();
        for (NDA__c nda : toInsert) {
            ndaByDisposition.put(nda.Disposition__c, nda.Id);
        }

        // 🔴 OBSTACLE 2 OF 2 — THE BACK-STAMP MUST BE ASYNC, AND IT IS A LOCK, NOT A PERMISSION.
        // See the class header and LoiPrimaryStampQueueable's, which records the two failed
        // attempts (bare DML -> TypeException; SYSTEM_MODE -> ENTITY_IS_LOCKED) that produced
        // this pattern.
        //
        // 🔴 THIS HALF EXISTS ONLY BECAUSE `Disposition__c.Primary_NDA__c` EXISTS. It is the only
        // Primary_* lookup on the object — there is no Primary_LOI__c and no Primary_Contract__c —
        // which is exactly why the LOI and PSA blocks below have no Queueable and must not be
        // given one.
        //
        // The enqueue is GUARDED exactly as OpportunityReviewService's is: this trigger can fire
        // inside an async context that has already spent its chained-job budget (the async cap is
        // 1), and an uncaught LimitException here would roll back the stage change — or the
        // approval — it is riding on.
        //
        // ⚠ RESIDUAL, STATED RATHER THAN HIDDEN: when the budget IS exhausted the stamp is
        // silently skipped and Primary_NDA__c stays null. The NDA itself still exists and is
        // still reachable from the disposition's related list, so nothing is lost — but anything
        // that resolves THROUGH the lookup finds nothing. Identical trade, identical wording, to
        // the LOI block; if it ever needs closing, close both.
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new DispositionNdaStampQueueable(ndaByDisposition));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // `LOI` STAGE — the sell-side LOI. Tranche 3B fix pass (review C1).
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Opens one disposition LOI per entrant.
     *
     * ── 🔴 THE DML MODE, RE-ARGUED FROM SCRATCH. IT IS NOT INHERITED FROM THE NDA BLOCK. ──
     * Three questions, answered independently, because the NDA block's answers are right there for
     * the copying and two of its three premises do not hold here.
     *
     * 1. CRUD — SYSTEM_MODE IS REQUIRED. `DPEG_Disposition_Edit` grants `LOI__c`
     *    `allowCreate = false` (measured in the permission-set file, alongside allowEdit = true /
     *    allowRead = true), on the same premise D16.1 set for `NDA__c`: creation is this trigger's
     *    job. A `USER_MODE` insert therefore fails for the exact persona the feature exists for.
     *
     * 2. FLS — SYSTEM_MODE IS REQUIRED AGAIN, INDEPENDENTLY, AND THIS LEG SURVIVES EVEN IF SOMEONE
     *    LATER GRANTS allowCreate. `LOI__c.Disposition__c` is a Tranche 3B field, and a
     *    Metadata-API-deployed custom field arrives with NO field permissions for ANY profile,
     *    System Administrator included. Under `USER_MODE` the insert would be refused for
     *    EVERYONE — including the admin who deployed it — on the one field that makes the row a
     *    disposition LOI at all. Measured on the READ side of this very field on 2026-08-09
     *    (`System.QueryException: No such column 'Disposition__c' on entity 'LOI__c'`).
     *
     * 3. THE APPROVAL LOCK — DOES NOT APPLY, AND THIS IS WHERE COPYING THE NDA BLOCK WOULD HAVE
     *    BEEN WRONG. Three separate facts, each sufficient on its own:
     *      (a) THERE IS NO PARENT WRITE AT ALL. `Disposition__c` has no `Primary_LOI__c` — repo
     *          grep: `Primary_NDA__c` is the only Primary_* field on the object. The NDA block's
     *          Queueable exists SOLELY because `SYSTEM_MODE` does not lift an approval lock and it
     *          writes back to the locked parent. With nothing to write back, there is nothing to
     *          defer: a Queueable here would be a job that does nothing, and a reader would take
     *          its existence as evidence of a hazard that is not present.
     *      (b) `LOI` IS NOT ANY APPROVAL'S ENTRY STAGE. Read from the three approvalProcess files:
     *          `Sale_Decision_Approval` keys on `Disposition Readiness`, `Broker_Selection_Approval`
     *          on `BOV Outreach`, `Closing_Approval` on `Closing`. So entering `LOI` never coincides
     *          with an approval starting or finishing.
     *      (c) NONE OF THE THREE APPROVALS PERFORMS A FIELD UPDATE AT ALL (zero FieldUpdate
     *          elements across all three files), so `Disposition_Stage__c` is only ever moved to
     *          `LOI` by a human edit or a data load — never by an approval process's own field
     *          update running as a read-only APPROVER. That is the fact
     *          `OpportunityReviewService`'s LOI block turns on, and it is absent here.
     *    ⚠ ONE HONEST CAVEAT: `recordEditability = AdminOnly` means an ADMIN can still edit — and
     *    therefore re-stage — a disposition while an approval is pending. Even on that path the
     *    conclusion holds: the child is not the record under approval so it is not locked, and
     *    there is still no parent write to throw.
     *
     * 4. allOrNone = true, matching the NDA block but for its own reason. With `false`, a failed
     *    insert would leave the disposition parked at `LOI` with no negotiation record and NOTHING
     *    downstream would notice — unlike the NDA case, where All_NDAs_Signed_Before_Progression
     *    would at least block the next hop. A refused stage change is loud; an empty `LOI` stage is
     *    silent, and silence is the failure mode this whole tranche keeps paying for.
     *
     * ── IDEMPOTENCY: SIMPLE PRESENCE ─────────────────────────────────────────
     * "This disposition already has an LOI" is the whole test — there is no Party_Role__c
     * equivalent and only one kind of disposition LOI. ⚠ Deliberately NOT scoped to the
     * Disposition_LOI record type, for the same reason as the NDA block: in the window before gate
     * T-A1 a disposition LOI can legitimately sit on MASTER, and a record-type-scoped check would
     * mint a second one. The `Disposition__c` lookup is the key.
     *
     * ⚠ CONSEQUENCE WORTH STATING: a second buyer on the same disposition does NOT get a second
     * auto-created LOI. That is correct for auto-create (re-entering the stage must not duplicate)
     * and it means a genuine second-round LOI is a hand-created record, exactly as a broker NDA is.
     *
     * ── ⚠ THE RECORD-TYPE STAMP IS GUARDED (isAvailable()), NOT UNCONDITIONAL ──
     * Same choice and the same read-back-test mitigation as the NDA block and
     * OpportunityReviewService. MEASURED 2026-08-09 on usman-dpeg: an UNGUARDED RecordTypeId stamp
     * throws INVALID_CROSS_REFERENCE_KEY where a guarded one silently no-ops, and a record type
     * assigned to no profile resolves a real Id while being available to nobody — administrators
     * included, because Modify All Data is an OBJECT permission and confers no record-type access.
     * Unguarded, this insert would roll the user's own stage change back with a raw platform error
     * for every user until gate T-A1 runs.
     *
     * 🔴 WHAT THE GUARD COSTS HERE IS THE NDA'S COST, NOT THE PSA'S. A Master-type disposition LOI
     * seeds at 'Received', RecordStageAdvanceService falls back to the ACQUISITION sequence, and
     * that map has no 'Received' entry — so Advance Stage and both loop actions refuse and the
     * record cannot move at all. Visible on the record, like the NDA; the real remedy is gate T-A1,
     * not a code change.
     */
    private static void openDispositionLois(Set<Id> entrants) {
        if (entrants.isEmpty()) {
            return;
        }
        for (LOI__c existing : LoiSelector.selectByDispositionIds(entrants)) {
            entrants.remove(existing.Disposition__c);
        }
        if (entrants.isEmpty()) {
            return;
        }

        Id recordTypeId = recordTypeIdFor(LOI__c.SObjectType, DISPOSITION_LOI_RECORD_TYPE);
        List<LOI__c> toInsert = new List<LOI__c>();
        for (Id dispositionId : entrants) {
            LOI__c loi = new LOI__c(
                Disposition__c = dispositionId,
                Stage__c = DISPOSITION_LOI_INITIAL_STAGE
            );
            if (recordTypeId != null) {
                loi.RecordTypeId = recordTypeId;
            }
            // ⚠ Opportunity__c is deliberately left NULL. A disposition LOI hangs off
            // Disposition__c only, and that blank is what CounterOfferService.isSaleSide falls back
            // to while every row still sits on Master. Populating it would make the LOI look
            // buy-side to every consumer that checks the lookup.
            toInsert.add(loi);
        }
        Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);
        // NO PARENT STAMP AND NO QUEUEABLE — see point 3 above. Do not add one "for symmetry".
    }

    // ═════════════════════════════════════════════════════════════════════════
    // `PSA` STAGE — the sell-side PSA / Contract Review. Tranche 3C fix pass (review C1).
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Opens one disposition Contract Review per entrant.
     *
     * ── 🔴 THE DML MODE — SAME FOUR QUESTIONS, ANSWERED FOR THIS OBJECT ──────
     * 1. CRUD: `DPEG_Disposition_Edit` grants `Contract_Review__c` `allowCreate = false` (measured
     *    in the permission-set file, alongside allowEdit = true / allowRead = true, and argued
     *    there on the D16.1 premise that creation is this trigger's job). SYSTEM_MODE required.
     * 2. FLS: `Contract_Review__c.Disposition__c` is a Tranche 3C field with no field permissions
     *    for any profile, System Administrator included. SYSTEM_MODE required independently, and
     *    this leg survives a later `allowCreate` grant.
     * 3. APPROVAL LOCK: does not apply. `Disposition__c` has no `Primary_Contract__c` so there is
     *    NO PARENT WRITE; `PSA` is not any approval's entry stage (`Sale_Decision` = Disposition
     *    Readiness, `Broker_Selection` = BOV Outreach, `Closing` = Closing); and none of the three
     *    approvals performs a field update, so the stage is only ever entered by a human edit or a
     *    data load, never by an approval running as a read-only approver. No Queueable, and adding
     *    one would assert a hazard that is not there.
     * 4. allOrNone = true: an empty `PSA` stage is silent, a refused stage change is loud.
     *
     * ── 🔴 THE INITIAL VALUE IS Negotiation_Status__c, NEVER Stage__c ─────────
     * `Stage__c` on this object is recomputed by the active before-save flow
     * `Contract_Review_Stage_Sync`, so writing it commits and is silently discarded. See
     * DISPOSITION_PSA_INITIAL_STATUS. This is the one shape difference between this block and the
     * LOI block, and it is a property of the OBJECT, not of the side of the deal.
     *
     * ⚠ Opportunity__c IS DELIBERATELY LEFT NULL, AND HERE THAT IS LOAD-BEARING RATHER THAN MERELY
     * TIDY. `ContractExecutionService.handleExecution` runs its acquisition arm off
     * `Opportunity__c` and its disposition arm off `Disposition__c`, through two independent `if`s
     * — so a row carrying BOTH parents runs BOTH arms and an executed sell-side PSA would stamp an
     * Opportunity and arm a Day-0 Transaction fan-out on a deal that is not being bought. The
     * Disposition_PSA record type file records the same blank as load-bearing for the same reason.
     *
     * ── IDEMPOTENCY: SIMPLE PRESENCE, NOT SCOPED TO THE RECORD TYPE ──────────
     * 🔴 THE UNSCOPED CHECK MATTERS MORE ON THIS OBJECT THAN ON THE OTHER TWO. Both PSA record
     * types expose the IDENTICAL four `Negotiation_Status__c` values, so a Master-type disposition
     * PSA walks its whole path correctly and looks completely normal — it is wrong only about which
     * PERSONA may drive it. A record-type-scoped idempotency check would therefore mint a SECOND,
     * duplicate PSA against a first one that nothing else in the system reports as anomalous.
     *
     * ── ⚠ THE RECORD-TYPE STAMP IS GUARDED (isAvailable()) ───────────────────
     * Same guard, same measured reason as the other two blocks. 🔴 BUT BE HONEST THAT THE GUARD'S
     * COST IS QUIETER HERE, exactly as review J1 says of the sibling fallback in
     * RecordStageAdvanceService: a Master-type disposition PSA is not dead — it advances fine and
     * every toast is right — it is simply un-advanceable by the DISPOSITION persona and perfectly
     * advanceable by an acquisitions one, because the gate is picked off the record type. Nothing
     * in the system will notice. The remedy is post-deploy gate T-A1 plus its persona step, not a
     * code change; the record-type read-back test is the only permanent falsifier.
     */
    private static void openDispositionContractReviews(Set<Id> entrants) {
        if (entrants.isEmpty()) {
            return;
        }
        for (Contract_Review__c existing : ContractReviewSelector.selectByDispositionIds(entrants)) {
            entrants.remove(existing.Disposition__c);
        }
        if (entrants.isEmpty()) {
            return;
        }

        Id recordTypeId =
            recordTypeIdFor(Contract_Review__c.SObjectType, DISPOSITION_PSA_RECORD_TYPE);
        List<Contract_Review__c> toInsert = new List<Contract_Review__c>();
        for (Id dispositionId : entrants) {
            Contract_Review__c cr = new Contract_Review__c(
                Disposition__c = dispositionId,
                Negotiation_Status__c = DISPOSITION_PSA_INITIAL_STATUS
            );
            if (recordTypeId != null) {
                cr.RecordTypeId = recordTypeId;
            }
            toInsert.add(cr);
        }
        Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);
        // NO PARENT STAMP AND NO QUEUEABLE — see point 3 above.
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SHARED
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The record type Id for a developer name on an object, or null when it does not exist in this
     * org or is not available to the running user.
     *
     * Null is a legitimate answer, not an error — the caller then leaves RecordTypeId unset and the
     * platform applies its own default. See each block's Javadoc for what that costs on that object
     * and why a loud failure was still rejected.
     *
     * A describe, not a query — it costs no SOQL. Callers resolve it ONCE per chunk.
     *
     * ⚠ The developer-name lookup is case-SENSITIVE (getRecordTypeInfosByDeveloperName keys its map
     * that way), so the three constants above must match the recordTypes/ file names exactly. There
     * is deliberately no allow-list guard here — unlike TestDataFactory, every argument is one of
     * this class's own private constants, so a typo is a compile-time-visible edit to a named
     * constant rather than a caller mistake.
     */
    private static Id recordTypeIdFor(Schema.SObjectType objectType, String developerName) {
        Schema.RecordTypeInfo info = objectType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }
}
