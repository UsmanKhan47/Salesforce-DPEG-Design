/**
 * Creates review child records for an Opportunity. Two triggers for a review:
 *
 *   1. Stage entry - "Development Review" (Land path) / "Construction Review"
 *      (Retail path) / "PSA" (opens the Contract Review).
 *   2. Input-needed checkboxes - Development_Input_Needed__c /
 *      Construction_Input_Needed__c flipping true opens the matching review at
 *      ANY stage, which is how Development/Construction engage BEFORE
 *      underwriting without reordering the sales path.
 *
 * Idempotent: never creates a second review of the same type for one
 * Opportunity, so re-entering a stage or re-flipping a checkbox is a no-op.
 *
 * ── 🔴 RECORD TYPES: THIS CLASS CREATES THREE OBJECTS THAT ARE GAINING THEM ──
 * Decision D16.3 (2026-08-09). NDA__c, LOI__c and Contract_Review__c each gain an
 * Acquisition / Disposition record-type pair across tranches 3A / 3B / 3C. This class
 * predates all of them and stamped a record type on NONE of its inserts, so every
 * auto-created ACQUISITION child would land on the MASTER record type — one deal at a
 * time, silently, in a live working flow. That is damage to a shipping feature caused by
 * adding record types elsewhere, not a disposition problem.
 *
 * The fix lands per tranche, with the object whose record types arrive:
 *   3A  ensureNda                 -> Acquisition_NDA   ✅ DONE
 *   3B  the LOI block below       -> Acquisition_LOI   ✅ DONE (2026-08-09)
 *   3C  the Contract Review block -> Acquisition_PSA   ✅ DONE (2026-08-09)
 *
 * ── ⚠ ALL THREE STAMPS ARE GUARDED (isAvailable()), NOT UNCONDITIONAL — AND FOR THREE
 *      DIFFERENT REASONS. D20/W2 REQUIRED EACH CASE TO BE RE-ARGUED, NOT INHERITED. ──
 * The design (§5.2) proposed stamping unconditionally so a missing record type fails LOUDLY.
 * That is rejected on ALL THREE inserts, on blast radius — but the blast radius is a
 * different one each time, and a future reader must not collapse the three arguments into
 * one. Three identical-looking lines of code, three separate justifications; the fact that
 * they AGREE is a conclusion, not a premise.
 *
 * MEASURED 2026-08-09 on usman-dpeg and common to both: an unguarded RecordTypeId stamp
 * throws INVALID_CROSS_REFERENCE_KEY ("this ID value isn't valid for the user") where an
 * isAvailable()-guarded one silently no-ops. Post-deploy gate T-A1 (profile record-type
 * assignment) is what clears it, and T-A1 is NOT deployable from this repo (profiles/** is
 * .forceignore'd).
 *
 *   ensureNda   RUNS ON EVERY Opportunity INSERT — including Database.convertLead, i.e. the
 *               automated inbound Broker-Protection pipeline. It is an AFTER-insert trigger
 *               path, so an exception ROLLS THE OPPORTUNITY BACK. Unguarded, pre-A1 that is
 *               not "one loud failure" — it is "nobody can create a deal, and no Lead can
 *               convert", plus a repo-wide red suite that would make this branch unverifiable.
 *
 *   the LOI     runs on ENTRY TO THE LOI STAGE ONLY, so lead conversion and deal creation are
 *   block      untouched: strictly narrower. The reason to guard it anyway is WHO it runs as
 *               and WHAT it would take down. The LOI stage is entered by the LOI approval
 *               process's own field update, so this code executes as the APPROVER inside the
 *               approval transaction. An exception here does not cost an LOI — it rolls back
 *               the APPROVAL, and the approver is told "this ID value isn't valid for the
 *               user" on an Approve click. That is the exact shape of the ApprovalAuditService
 *               incident (D10: a TypeException escaped a DmlException-only catch and "Nikhil
 *               could not approve at all"), reproduced one tranche later.
 *               🔴 AND THE PRINCIPAL IS THE PROFILE MOST LIKELY TO BE MISSED BY T-A1. Record
 *               types are assigned per PROFILE by hand; an admin doing T-A1 thinks about deal
 *               drivers, not about read-only principals who never create an LOI themselves.
 *               So the failure this guard prevents is not merely severe, it is the LIKELIEST
 *               incomplete-A1 outcome — and it lands on the user least able to diagnose it.
 *
 *   the         RUNS ON ENTRY TO THE PSA STAGE, driven by a DEAL DRIVER WHO HAS EDIT. That is
 *   Contract    the easy half and it is why this case had to be argued from scratch: it is
 *   Review      neither ensureNda's (every Opportunity insert, lead conversion included) nor the
 *   block       LOI block's (runs as a read-only approver inside an approval). MEASURED
 *   (3C)        2026-08-09 — the only route into 'PSA' is StageAdvanceService.advance() from
 *               'LOI' (NEXT_STAGE `'LOI' => 'PSA'`), which asserts
 *               OpportunityActionPermissionService.assertDealActionAccess() first. 'PSA' is NOT
 *               in ALLOWED_EXPLICIT_TARGETS, so advanceTo cannot reach it; NO approval field
 *               update writes it (the only two write 'Underwriting' and 'LOI'); and NO flow
 *               writes StageName at all. On that evidence alone, unconditional would be
 *               defensible — one loud error, on one click, for one privileged user.
 *
 *               🔴 TWO FACTS OVERTURN IT, AND BOTH ARE SPECIFIC TO THIS BLOCK.
 *
 *               (a) 'PSA' IS A SEQUENCED GATE WITH EXACTLY ONE ROUTE, SO BLOCKING IT IS NOT
 *                   "ONE FAILED CLICK" — IT IS THE WHOLE DOWNSTREAM MODULE. A deal that cannot
 *                   enter PSA has no Contract_Review__c, so psaVersionLog has no parent, the PSA
 *                   negotiation cannot be recorded, Negotiation_Status__c can never reach
 *                   'Executed', ContractExecutionService never fires, Contract_Executed_Date__c
 *                   is never stamped — and openTransactionsOnAboutToClose READS THAT STAMP, so
 *                   the Day-0 checklist is mis-dated even if the deal is forced onward by hand.
 *                   One unassigned profile parks every acquisition in the org at LOI. ensureNda
 *                   blocks deal CREATION; this blocks deal PROGRESSION at the point the contract
 *                   module begins.
 *
 *               (b) 🔴 THIS INSERT SHARES ONE ALL-OR-NONE TRANSACTION WITH FOUR SIBLING CHILDREN
 *                   THAT HAVE NOTHING TO DO WITH RECORD TYPES. createReviewRecords handles FIVE
 *                   child types in ONE method and ONE trigger invocation, and the Contract Review
 *                   insert runs FIRST — before Underwriting, before the LOI. On a bulk stage move
 *                   where deals enter DIFFERENT stages, one PSA-entering deal on an unassigned
 *                   profile would abort the chunk before the Underwriting and LOI children were
 *                   even built, taking their Primary_* stamps and the LOI queueable with it.
 *                   ensureNda is a separate method and owns its own transaction; this one does
 *                   not. A method is only as robust as its most fragile stamp, and there is no
 *                   version of "fail loudly" that fails loudly about the RIGHT record here.
 *
 *               ⚠ A third, weaker point, recorded because it is true but must not be mistaken for
 *               the argument: an unconditional stamp would make this ONE method contain three
 *               different failure modes (four bare inserts, one guarded stamp, one unguarded).
 *               Consistency is a tie-breaker, not a reason.
 *
 * ⚠ AccessLevel.SYSTEM_MODE ON THE LOI INSERT DOES NOT MAKE THE STAMP SAFE, AND MUST NOT BE
 * READ AS DOING SO. SYSTEM_MODE lifts CRUD and FLS; record-type AVAILABILITY is a profile
 * assignment, which is neither — the same narrowness this file already records for approval
 * locks ("SYSTEM_MODE lifts CRUD/FLS but does NOT lift an approval lock"). 🔴 UNDETERMINED,
 * stated rather than assumed: the 2026-08-09 measurement was taken on a BARE `insert`, not on
 * an explicit AccessLevel.SYSTEM_MODE one, so whether SYSTEM_MODE would in fact have accepted
 * an unavailable record type was never tested. If it WOULD, this guard is over-conservative
 * here and declines a stamp the DML would have taken — which makes a Master-type LOI MORE
 * likely on this block than on ensureNda, not less. That residual is why the test below
 * asserts unconditionally.
 *
 * REJECTED ALTERNATIVES, both considered for the LOI block specifically:
 *   - stamp unconditionally inside a try/catch and retry without the record type — converts
 *     one clear condition into two, inside an all-or-none insert in an after-update trigger;
 *   - defer the stamp to LoiPrimaryStampQueueable alongside the Primary_LOI__c back-stamp —
 *     the queueable runs as the SAME principal, so the availability problem is identical, and
 *     a failure there is a failed AsyncApexJob nobody watches, i.e. strictly MORE silent.
 *
 * Each guard's own failure mode — a silent Master-type child — is the very regression D16.3
 * fixes, so it is NOT left silent. OpportunityReviewServiceTest
 * .ensureNda_stampsTheAcquisitionRecordType, .loiBlock_stampsTheAcquisitionRecordType and
 * .contractReviewBlock_stampsTheAcquisitionRecordType read RecordTypeId BACK and fail
 * UNCONDITIONALLY, naming gate T-A1. Production degrades safely; the tests are where the
 * loudness lives. Same shape and same reasoning as TestDataFactoryTest
 * .createDisposition_defaultOverload_stampsOnMarketRecordType (D13 residual 1).
 *
 * ⚠ WHAT A MASTER-TYPE CONTRACT REVIEW ACTUALLY COSTS, stated so the 3C guard's price is not
 * quietly understated: it matches NEITHER PSA Path, exposes the UNION of both types'
 * Ball_In_Court__c values (so a buy-side PSA offers 'Buyer', which on a purchase names DPEG
 * itself), and sits outside the record-type-scoped sharing this tranche gives the disposition
 * personas. It is NOT, however, functionally dead the way a Master-type DISPOSITION NDA is:
 * both PSA record types share ONE Negotiation_Status__c sequence, so
 * RecordStageAdvanceService's defaultTypeKey routes it to a map that genuinely fits and
 * Advance Stage keeps working. What it gets wrong is the GATE — it answers to DEAL_DRIVER,
 * which is exactly right for the acquisition rows this block is the only creator of. That
 * asymmetry is what makes the guard affordable here and is part of the (a)/(b) argument above.
 *
 * ⚠ A creation that SUCCEEDED is not evidence the type landed. Any verification of this must
 * re-query RecordTypeId; the in-memory copy carries whatever was assigned, guard or no guard.
 *
 * Each describe is resolved ONCE per invocation, before its build loop — it costs zero SOQL,
 * but a per-record describe in a 251-deal insert would be 251 of them.
 */
public with sharing class OpportunityReviewService {

    @TestVisible private static final String DEV_STAGE = 'Development Review';
    @TestVisible private static final String CON_STAGE = 'Construction Review';
    @TestVisible private static final String CONTRACT_STAGE = 'PSA';
    @TestVisible private static final String UW_STAGE = 'Underwriting';
    @TestVisible private static final String LOI_STAGE = 'LOI';

    /**
     * Developer name of the record type every auto-created ACQUISITION NDA is stamped with
     * (D7 / D16.3). Case must match objects/NDA__c/recordTypes/ exactly —
     * getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY.
     */
    @TestVisible
    private static final String ACQUISITION_NDA_RECORD_TYPE = 'Acquisition_NDA';

    /**
     * Developer name of the record type every auto-created ACQUISITION LOI is stamped with
     * (D6 / D16.3, Tranche 3B). Case must match objects/LOI__c/recordTypes/ exactly —
     * getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY.
     */
    @TestVisible
    private static final String ACQUISITION_LOI_RECORD_TYPE = 'Acquisition_LOI';

    /**
     * Developer name of the record type every auto-created ACQUISITION Contract Review is stamped
     * with (D16.3, Tranche 3C). Case must match objects/Contract_Review__c/recordTypes/ exactly —
     * getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY.
     */
    @TestVisible
    private static final String ACQUISITION_PSA_RECORD_TYPE = 'Acquisition_PSA';

    /**
     * Called from the Opportunity after-insert / after-update trigger.
     * @param newOpps Trigger.new
     * @param oldMap  Trigger.oldMap on update; null on insert.
     */
    public static void createReviewRecords(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Set<Id> devOpps = new Set<Id>();
        Set<Id> conOpps = new Set<Id>();
        Set<Id> contractOpps = new Set<Id>();
        Set<Id> uwOpps = new Set<Id>();
        Set<Id> loiOpps = new Set<Id>();
        Map<Id, Id> propertyByOpp = new Map<Id, Id>();
        Map<Id, Id> ownerByOpp = new Map<Id, Id>();

        for (Opportunity o : newOpps) {
            Opportunity prior = (oldMap == null) ? null : oldMap.get(o.Id);
            String priorStage = (prior == null) ? null : prior.StageName;
            Boolean stageChanged = priorStage != o.StageName;
            Boolean devFlip = o.Development_Input_Needed__c == true
                && (prior == null || prior.Development_Input_Needed__c != true);
            Boolean conFlip = o.Construction_Input_Needed__c == true
                && (prior == null || prior.Construction_Input_Needed__c != true);

            if ((stageChanged && o.StageName == DEV_STAGE) || devFlip) {
                devOpps.add(o.Id);
            }
            if ((stageChanged && o.StageName == CON_STAGE) || conFlip) {
                conOpps.add(o.Id);
            }
            if (stageChanged && o.StageName == CONTRACT_STAGE) {
                contractOpps.add(o.Id);
            }
            if (stageChanged && o.StageName == UW_STAGE) {
                uwOpps.add(o.Id);
            }
            if (stageChanged && o.StageName == LOI_STAGE) {
                loiOpps.add(o.Id);
                propertyByOpp.put(o.Id, o.Property__c);
                ownerByOpp.put(o.Id, o.OwnerId);
            }
        }
        if (devOpps.isEmpty() && conOpps.isEmpty() && contractOpps.isEmpty()
                && uwOpps.isEmpty() && loiOpps.isEmpty()) {
            return;
        }

        // Idempotency: drop opps that already have a review of the matching type.
        // SOQL relocated to the per-object selectors (Module A2) per ARCHITECTURE.md §2.
        for (Development_Feasibility_Review__c d : DevelopmentFeasibilityReviewSelector.selectByOpportunityIds(devOpps)) {
            devOpps.remove(d.Opportunity__c);
        }
        for (Construction_Feasibility_Review__c c : ConstructionFeasibilityReviewSelector.selectByOpportunityIds(conOpps)) {
            conOpps.remove(c.Opportunity__c);
        }
        for (Contract_Review__c cr : ContractReviewSelector.selectByOpportunityIds(contractOpps)) {
            contractOpps.remove(cr.Opportunity__c);
        }
        for (Underwriting__c uw : UnderwritingSelector.selectByOpportunityIds(uwOpps)) {
            uwOpps.remove(uw.Opportunity__c);
        }
        for (LOI__c loi : LoiSelector.selectByOpportunityIds(loiOpps)) {
            loiOpps.remove(loi.Opportunity__c);
        }

        List<Development_Feasibility_Review__c> devToInsert = new List<Development_Feasibility_Review__c>();
        for (Id oppId : devOpps) {
            devToInsert.add(new Development_Feasibility_Review__c(
                Opportunity__c = oppId, Stage__c = 'Requested',
                Requested_By__c = UserInfo.getUserId()));
        }
        List<Construction_Feasibility_Review__c> conToInsert = new List<Construction_Feasibility_Review__c>();
        for (Id oppId : conOpps) {
            conToInsert.add(new Construction_Feasibility_Review__c(
                Opportunity__c = oppId, Stage__c = 'Requested',
                Requested_By__c = UserInfo.getUserId()));
        }
        // Resolved ONCE for the whole trigger chunk, before the loop — a describe per record would
        // be one per deal on a bulk stage move, for an answer that cannot vary within a
        // transaction. Same shape as ensureNda's and the LOI block's.
        Id acquisitionPsaRecordTypeId = acquisitionPsaRecordTypeId();
        List<Contract_Review__c> contractToInsert = new List<Contract_Review__c>();
        for (Id oppId : contractOpps) {
            // ⚠ 'PSA Drafting' is Stage__c, which is a DERIVED PROJECTION — the
            // Contract_Review_Stage_Sync before-save flow recomputes it from
            // Negotiation_Status__c on every save, so this seed is cosmetic and is
            // immediately replaced by the flow's mapping of the status default ('Initial
            // Draft' -> 'PSA Drafting', i.e. the same value). It is left exactly as it was:
            // changing it would be a no-op that reads like a fix.
            Contract_Review__c cr = new Contract_Review__c(
                Opportunity__c = oppId, Stage__c = 'PSA Drafting');
            // 🔴 GUARDED, and the guard was RE-ARGUED for THIS block, not inherited from
            // ensureNda or from the LOI block (D20/W2). See the class header, argument (a)+(b):
            // 'PSA' has exactly ONE route in and this insert shares an all-or-none transaction
            // with four sibling children. Null here is a legitimate answer.
            if (acquisitionPsaRecordTypeId != null) {
                cr.RecordTypeId = acquisitionPsaRecordTypeId;
            }
            contractToInsert.add(cr);
        }

        if (!devToInsert.isEmpty()) {
            insert devToInsert;
        }
        if (!conToInsert.isEmpty()) {
            insert conToInsert;
        }
        if (!contractToInsert.isEmpty()) {
            insert contractToInsert;
            // Stamp the new Contract Review back onto the Opportunity's Primary_Contract__c
            // so the Contract tab can show its fields via spanning relationships. The
            // re-fired trigger no-ops here because the stage is unchanged on this update.
            List<Opportunity> oppsToStamp = new List<Opportunity>();
            for (Contract_Review__c cr : contractToInsert) {
                oppsToStamp.add(new Opportunity(Id = cr.Opportunity__c, Primary_Contract__c = cr.Id));
            }
            update oppsToStamp;
        }

        // Entering Underwriting opens the Underwriting record (same primary-stamp
        // pattern as the Contract Review at PSA).
        if (!uwOpps.isEmpty()) {
            List<Underwriting__c> uwToInsert = new List<Underwriting__c>();
            for (Id oppId : uwOpps) {
                uwToInsert.add(new Underwriting__c(
                    Opportunity__c = oppId, Stage__c = 'Requested', Status__c = 'In Progress'));
            }
            insert uwToInsert;
            List<Opportunity> uwStamps = new List<Opportunity>();
            for (Underwriting__c uw : uwToInsert) {
                uwStamps.add(new Opportunity(Id = uw.Opportunity__c, Primary_Underwriting__c = uw.Id));
            }
            update uwStamps;
        }

        // Entering LOI opens the LOI record. Added 2026-08-05: LOI was the ONLY child in the deal
        // tree with no auto-creation, so principal approval moved a deal to the LOI stage with
        // nothing to work on.
        //
        // 🔴 STAMPING Primary_LOI__c IS THE LOAD-BEARING HALF, not bookkeeping.
        // ApprovalAuditService's LOI gate resolves its target through
        // OpportunitySelector.selectPrimaryLoiByIds, so a null Primary_LOI__c makes the LOI
        // approval stamp NOTHING — silently, because that service swallows its own failures. An
        // LOI created without this stamp would reproduce the Underwriting-gate defect one stage
        // later. Same insert-then-stamp shape as Contract Review / Underwriting / NDA above.
        //
        // Property__c is carried from the deal so the LOI is not orphaned from the asset; it is
        // read from Trigger.new rather than re-queried. A deal with no Property yields null, which
        // is the pre-existing state for a manually created LOI and is not made worse here.
        if (!loiOpps.isEmpty()) {
            // Resolved ONCE for the whole trigger chunk, before the loop — a describe per record
            // would be one per deal on a bulk stage move, for an answer that cannot vary within a
            // transaction. Same shape as ensureNda's.
            Id acquisitionLoiRecordTypeId = acquisitionLoiRecordTypeId();
            List<LOI__c> loiToInsert = new List<LOI__c>();
            for (Id oppId : loiOpps) {
                LOI__c loi = new LOI__c(
                    Opportunity__c = oppId,
                    Property__c = propertyByOpp.get(oppId),
                    // 🔴 OWNER MUST BE THE DEAL'S OWNER, NOT THE RUNNING USER. Without this the
                    // LOI is owned by whoever's transaction created it — and that is the APPROVER,
                    // because the LOI stage is entered by the approval's own field update. With
                    // OWD Private on LOI__c that made the record UNEDITABLE by the deal team: the
                    // deal driver holds ViewAllRecords (so it is visible) but not ModifyAllRecords,
                    // and the role hierarchy grants access upward, not down from a principal. The
                    // observed symptom was "insufficient access rights on object id" when the deal
                    // driver clicked Advance Stage on the LOI. The five sibling children never hit
                    // this because a deal driver creates them and therefore already owns them.
                    OwnerId = ownerByOpp.get(oppId),
                    // ⚠ 'Draft' is Acquisition_LOI's starting stage and is NOT on Disposition_LOI's
                    // value set (which starts at 'Received'). Record-type picklist restriction is
                    // UI-only and Apex DML does not enforce it, so pairing the record type with the
                    // right seed stage is this method's responsibility, not the platform's — the
                    // same pairing ensureNda makes between Acquisition_NDA and 'Pending'.
                    Stage__c = 'Draft',
                    LOI_Status__c = 'Draft');
                // 🔴 GUARDED, and the guard was RE-ARGUED for this block rather than inherited from
                // ensureNda (D20/W2). See the class header: unguarded, an unavailable record type
                // throws INVALID_CROSS_REFERENCE_KEY inside the APPROVAL transaction and the
                // approver cannot approve at all. Null here is a legitimate answer.
                if (acquisitionLoiRecordTypeId != null) {
                    loi.RecordTypeId = acquisitionLoiRecordTypeId;
                }
                loiToInsert.add(loi);
            }
            // ⚠ EXPLICIT SYSTEM MODE — and this block genuinely differs from its five siblings
            // above, which deliberately keep a bare `insert`. Every other child is created when a
            // DEAL DRIVER moves the stage, and a deal driver has Edit. The LOI stage is the only
            // one entered by the APPROVAL PROCESS's own field update, so this code runs as the
            // APPROVER — who is read-only on both Opportunity and LOI__c (DPEG Principal PSG:
            // Read yes, Edit no, measured). LOI__c is not the record under approval, so it is not
            // locked and inserts fine here; the user sees the LOI immediately.
            Database.insert(loiToInsert, true, AccessLevel.SYSTEM_MODE);

            // 🔴 THE BACK-STAMP MUST BE ASYNC, AND IT IS A LOCK — NOT A PERMISSION.
            // Writing Primary_LOI__c back onto the deal from THIS transaction throws
            // ENTITY_IS_LOCKED: the Opportunity is locked for the duration of its own approval
            // (Underwriting_Approval declares recordEditability=AdminOnly), and AccessLevel
            // .SYSTEM_MODE does NOT lift an approval lock — it only lifts CRUD/FLS. Both approval
            // processes set finalApprovalRecordLock=false, so the deal unlocks at commit, which is
            // when the Queueable runs. Do not "simplify" this back to an inline update.
            Map<Id, Id> loiByOpp = new Map<Id, Id>();
            for (LOI__c loi : loiToInsert) {
                loiByOpp.put(loi.Opportunity__c, loi.Id);
            }
            // Guard the enqueue the same way EmailMessageTriggerHandler does: this trigger can fire
            // inside an async context that has already spent its chained-job budget, and an
            // uncaught LimitException here would roll back the approval it is riding on.
            if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new LoiPrimaryStampQueueable(loiByOpp));
            }
        }
    }

    /**
     * Every new Opportunity opens an NDA to track from the New stage, stamped
     * onto Primary_NDA__c so the NDA tab has a record and the signed-NDA gate has
     * something to check. Insert-only and idempotent - a deal never opens a second
     * NDA. Stamping Primary_NDA__c leaves StageName unchanged, so the
     * NDA_Signed_Before_Underwriting rule (ISCHANGED-gated) never fires here.
     *
     * 🔴 The NDA is stamped with the Acquisition_NDA record type (D16.3). Without it every
     * deal's NDA lands on Master, which matches NEITHER NDA Path, exposes all six Status__c
     * values, and puts the row outside the RecordType-scoped sharing rules the disposition
     * personas are given in this same tranche. The stamp is GUARDED — see the class header
     * for why loud-failure was rejected on THIS insert specifically, and for where the
     * loudness lives instead.
     *
     * ⚠ 'Pending' below is Acquisition_NDA's default and is NOT a valid value on
     * Disposition_NDA. Record-type picklist restriction is UI-only and Apex DML does not
     * enforce it, so the pairing of record type and seed status is this method's
     * responsibility, not the platform's.
     */
    public static void ensureNda(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        if (oldMap != null) {
            return; // only on insert
        }
        Set<Id> oppIds = new Set<Id>();
        for (Opportunity o : newOpps) {
            if (o.Primary_NDA__c == null) {
                oppIds.add(o.Id);
            }
        }
        if (oppIds.isEmpty()) {
            return;
        }
        // Idempotency: skip any deal that already has an NDA.
        // SOQL relocated to NdaSelector (Module A2) per ARCHITECTURE.md §2.
        for (NDA__c existing : NdaSelector.selectByOpportunityIds(oppIds)) {
            oppIds.remove(existing.Opportunity__c);
        }
        if (oppIds.isEmpty()) {
            return;
        }
        // Resolved ONCE for the whole trigger chunk — a describe per record would be 251
        // describes on a bulk load for an answer that cannot vary within a transaction.
        Id acquisitionNdaRecordTypeId = acquisitionNdaRecordTypeId();
        List<NDA__c> ndaToInsert = new List<NDA__c>();
        for (Id oppId : oppIds) {
            NDA__c nda = new NDA__c(Opportunity__c = oppId, Status__c = 'Pending');
            if (acquisitionNdaRecordTypeId != null) {
                nda.RecordTypeId = acquisitionNdaRecordTypeId;
            }
            ndaToInsert.add(nda);
        }
        insert ndaToInsert;
        List<Opportunity> ndaStamps = new List<Opportunity>();
        for (NDA__c nda : ndaToInsert) {
            ndaStamps.add(new Opportunity(Id = nda.Opportunity__c, Primary_NDA__c = nda.Id));
        }
        update ndaStamps;
    }

    /**
     * The Acquisition_NDA record type Id, or null when it does not exist in this org or is not
     * available to the running user.
     *
     * Null is a legitimate answer here, not an error — the caller then leaves RecordTypeId unset
     * and the platform applies its own default. That keeps an Opportunity creatable (and a Lead
     * convertible) in an org where the Tranche 3A record-type metadata has not deployed yet, or
     * where post-deploy gate T-A1 has not assigned it to the creating user's profile. See the
     * class header for why that trade was taken on THIS insert and must be re-argued, not
     * copied, for the LOI and Contract Review blocks.
     *
     * A describe, not a query — it costs no SOQL. Identical shape to
     * DispositionService.onMarketRecordTypeId and TestDataFactory.dispositionRecordTypeId, on
     * purpose: three creators of record-typed rows behaving three different ways is its own
     * defect source.
     */
    private static Id acquisitionNdaRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.NDA__c
            .getRecordTypeInfosByDeveloperName()
            .get(ACQUISITION_NDA_RECORD_TYPE);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /**
     * The Acquisition_LOI record type Id, or null when it does not exist in this org or is not
     * available to the running user — who, on this path, is the APPROVER.
     *
     * Null is a legitimate answer, not an error: the caller then leaves RecordTypeId unset and the
     * platform applies its own default, which keeps the LOI approval COMPLETABLE in an org where
     * the Tranche 3B record-type metadata has not deployed or where post-deploy gate T-A1 has not
     * assigned it to the approving principal's profile. See the class header for the full
     * guarded-vs-unconditional argument, which is NOT the same argument as ensureNda's and must not
     * be collapsed into it.
     *
     * ⚠ isAvailable() asks about the RUNNING USER while the insert it feeds runs in
     * AccessLevel.SYSTEM_MODE — a deliberate mismatch, biased toward not-stamping. See the header's
     * UNDETERMINED note.
     *
     * A describe, not a query — it costs no SOQL. Identical shape to acquisitionNdaRecordTypeId,
     * DispositionService.onMarketRecordTypeId and TestDataFactory's two resolvers, on purpose:
     * several creators of record-typed rows behaving several different ways is its own defect
     * source.
     */
    private static Id acquisitionLoiRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
            .getRecordTypeInfosByDeveloperName()
            .get(ACQUISITION_LOI_RECORD_TYPE);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /**
     * The Acquisition_PSA record type Id, or null when it does not exist in this org or is not
     * available to the running user — who, on this path, is the DEAL DRIVER who just advanced the
     * deal from LOI to PSA.
     *
     * Null is a legitimate answer, not an error: the caller then leaves RecordTypeId unset and the
     * platform applies its own default, which keeps the LOI -> PSA hop — and therefore the entire
     * downstream contract module — WORKING in an org where the Tranche 3C record-type metadata has
     * not deployed or where post-deploy gate T-A1 has not assigned it to the deal driver's profile.
     * See the class header for the full guarded-vs-unconditional argument, which was RE-ARGUED for
     * this block and is NOT the same argument as either ensureNda's or the LOI block's.
     *
     * ⚠ Unlike the LOI block, the insert this feeds is a BARE `insert` (deal drivers have Edit),
     * so there is no AccessLevel/isAvailable() mismatch to record here — the guard and the DML ask
     * about the same principal.
     *
     * A describe, not a query — it costs no SOQL. Identical shape to acquisitionNdaRecordTypeId,
     * acquisitionLoiRecordTypeId, DispositionService.onMarketRecordTypeId,
     * DispositionStageEntryService.dispositionNdaRecordTypeId and TestDataFactory's resolvers, on
     * purpose: several creators of record-typed rows behaving several different ways is its own
     * defect source.
     */
    private static Id acquisitionPsaRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosByDeveloperName()
            .get(ACQUISITION_PSA_RECORD_TYPE);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }
}