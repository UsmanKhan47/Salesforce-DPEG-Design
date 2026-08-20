/**
 * Creates review child records for an Opportunity. Two triggers for a review:
 *
 *   1. Stage entry - "Development Review" (Land path) / "Construction Review"
 *      (Retail path) / "Under Contract (PSA)" (opens the Contract Review).
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
 *   the         RUNS ON ENTRY TO THE 'Under Contract (PSA)' STAGE, driven by a DEAL DRIVER WHO
 *   Contract    HAS EDIT. That is the easy half and it is why this case had to be argued from
 *   Review      scratch: it is neither ensureNda's (every Opportunity insert, lead conversion
 *   block       included) nor the LOI block's (runs as a read-only approver inside an approval).
 *   (3C)        MEASURED 2026-08-09 — the only route into 'Under Contract (PSA)' is
 *               StageAdvanceService.advance() from 'LOI' (NEXT_STAGE
 *               `'LOI' => 'Under Contract (PSA)'`), which asserts
 *               OpportunityActionPermissionService.assertDealActionAccess() first.
 *               'Under Contract (PSA)' is NOT
 *               in ALLOWED_EXPLICIT_TARGETS, so advanceTo cannot reach it; NO approval field
 *               update writes it (the only two write 'Underwriting' and 'LOI'); and NO flow
 *               writes StageName at all. On that evidence alone, unconditional would be
 *               defensible — one loud error, on one click, for one privileged user.
 *
 *               🔴 TWO FACTS OVERTURN IT, AND BOTH ARE SPECIFIC TO THIS BLOCK.
 *
 *               (a) 'Under Contract (PSA)' IS A SEQUENCED GATE WITH EXACTLY ONE ROUTE, SO
 *                   BLOCKING IT IS NOT
 *                   "ONE FAILED CLICK" — IT IS THE WHOLE DOWNSTREAM MODULE. A deal that cannot
 *                   enter that stage has no Contract_Review__c, so psaVersionLog has no parent,
 *                   the PSA
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
 *                   where deals enter DIFFERENT stages, one 'Under Contract (PSA)'-entering deal
 *                   on an unassigned
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
 * ⚠ 🔴 WHAT A MASTER-TYPE CONTRACT REVIEW ACTUALLY COSTS — REWRITTEN 2026-08-14, BECAUSE THE
 * ANSWER CHANGED AND THE OLD ONE MADE THE GUARD LOOK CHEAPER THAN IT NOW IS.
 *
 * THIS BLOCK USED TO CONCLUDE: *"It is NOT, however, functionally dead the way a Master-type
 * DISPOSITION NDA is: both PSA record types share ONE Negotiation_Status__c sequence, so
 * RecordStageAdvanceService's defaultTypeKey routes it to a map that genuinely fits and Advance
 * Stage keeps working."* That was true, and observation 7 (design collision C9) killed its premise.
 * The two PSA record types no longer share a sequence:
 * `RecordStageAdvanceService.CONTRACT_REVIEW_NEXT_STAGE` was SPLIT into an acquisition map
 * (`Draft -> Negotiation -> Signed -> Executed`) and a disposition map (the old four values,
 * unchanged). Do not quote the old sentence; do not restore the shared map to make it true again.
 *
 * The cost NOW, in full:
 *   - it still matches NEITHER PSA Path, still exposes the UNION of both types' Ball_In_Court__c
 *     values (so a buy-side PSA offers 'Buyer', which on a purchase names DPEG itself), and still
 *     sits outside the record-type-scoped sharing the 3C tranche gives the disposition personas;
 *   - and Advance Stage NO LONGER "keeps working" unconditionally. It works only because THIS
 *     block seeds `Negotiation_Status__c = 'Draft'` explicitly (see the C3 fix at the call site):
 *     the row lands on a status the acquisition fallback map has an entry for, so the walk
 *     succeeds even with no record type. Had the seed been left to the field default, a Master-type
 *     row would be born on 'Initial Draft' and refuse on its first click.
 * ⇒ THE TWO FIXES ARE LOAD-BEARING TOGETHER, NOT SEPARATELY. The C3 seed is what keeps the guarded
 *   (null-tolerant) record-type stamp affordable after C9; without it the guard's own degraded path
 *   would produce a dead record, and the (a)/(b) argument above — which trades a loud failure for a
 *   silently Master-typed row — would no longer hold, because the row would not be merely
 *   mislabelled, it would be unusable.
 *
 * ⚠ A LEGACY Master-type row (created before this pack, still carrying 'Initial Draft') IS in that
 * dead state and cannot be rescued from here — the P3 row migration is scoped by record type, so it
 * is not migrated either. It refuses on its first click, naming its own stale status. Gate T-A1 /
 * T-B is the remedy. That refusal is the loud symptom RecordStageAdvanceService's header used to
 * complain this object did not have.
 *
 * ⚠ A creation that SUCCEEDED is not evidence the type landed. Any verification of this must
 * re-query RecordTypeId; the in-memory copy carries whatever was assigned, guard or no guard.
 *
 * ── 🔴 LOI OWNERSHIP IS THE ACQUISITION QUEUE (2026-08-15) ──────────────────────────────
 * The LOI block pins OwnerId to the `Acquisition` QUEUE on every auto-created acquisition LOI.
 *
 * WHY A QUEUE AT ALL: ownership of an auto-created LOI must be a property of THE PROCESS, not
 * of whichever principal's transaction happened to run the trigger. The LOI stage is entered by
 * the LOI approval process's own field update, so with no OwnerId at all the record is owned by
 * the APPROVER — and with OWD Private on LOI__c that made it uneditable by the deal team (the
 * observed symptom was "insufficient access rights on object id" when a deal driver clicked
 * Advance Stage). A queue is the only owner that is neither the approver nor any one person: it
 * survives reassignment, holiday and departure, and the Acquisitions team reaches it through one
 * sharing rule instead of through the role hierarchy, which grants access UPWARD and so never
 * reached a principal-owned row.
 *
 * ⚠ THIS SUPERSEDES, RATHER THAN INTRODUCES, AN OWNER ASSIGNMENT. Until this change the block
 * set `OwnerId = <the deal's owner>`, which was itself the fix for the approver-owns-it defect
 * described above. That earlier value is NOT deleted — it is now the DEGRADED path (see below),
 * because it is the best owner available when the queue cannot be resolved.
 *
 * 🔴 THE RESOLUTION FAILS SOFT, AND THE REASON IS THE SAME MEASURED ONE AS THE RECORD-TYPE
 * GUARD BESIDE IT. This block runs as a READ-ONLY APPROVER inside the approval transaction, so
 * an exception here does not cost an LOI — it rolls back the APPROVAL, and the approver is told
 * something unintelligible on an Approve click. That is the ApprovalAuditService/D10 shape
 * ("Nikhil could not approve at all"), and an unresolvable queue must never reproduce it. Two
 * failure modes are therefore both handled without throwing:
 *
 *   (a) THE QUEUE IS MISSING OR RENAMED — the selector returns null.
 *   (b) 🔴 THE QUEUE EXISTS BUT IS NOT ENABLED FOR LOI__c. This one is easy to miss and is the
 *       more likely of the two: a queue's `queueSobject` set is separate metadata, and
 *       queues/Acquisition.queue-meta.xml listed only Lead and Property__c when this code was
 *       written. Assigning a queue that cannot own the object is refused BY THE DML, i.e. it
 *       fails exactly where it is least affordable. It is therefore PRE-CHECKED, not caught:
 *       QueueGroupSelector.selectQueueIdByDeveloperNameForSObject asks QueueSobject, so "exists"
 *       and "may own an LOI" are one question with one answer and one query. Apex and metadata
 *       deploy independently and either may land first; both orders are safe.
 *
 * A residual try/catch sits behind those two, for anything neither anticipates. It is the
 * deliberately WIDE catch ApprovalAuditService was forced into (a TypeException is not a
 * DmlException), not a stylistic one — but note it cannot catch a LimitException, so the pre-check
 * remains the real mechanism and the catch is only the floor.
 *
 * ⚠ THE DEGRADED PATH IS DELIBERATELY *NOT* "LEAVE OwnerId UNSET". Unset means the running user,
 * and on this path the running user is the approver — the original defect. Falling back to the
 * deal's owner is strictly the lesser of the two, and is the behaviour this block already had.
 *
 * Each describe is resolved ONCE per invocation, before its build loop — it costs zero SOQL,
 * but a per-record describe in a 251-deal insert would be 251 of them. The queue lookup is a
 * QUERY, so the same rule binds harder: it is resolved once per invocation, inside the
 * `!loiOpps.isEmpty()` guard, so a chunk entering no LOI stage still costs zero SOQL for it.
 */
public with sharing class OpportunityReviewService {

    @TestVisible private static final String DEV_STAGE = 'Development Review';
    @TestVisible private static final String CON_STAGE = 'Construction Review';
    // ⚠ Renamed from 'PSA' (Acquisition Observations phase 2). This is the DECODED runtime
    // StageName; it carries spaces and parentheses but no '/', so no %2F encoding applies.
    @TestVisible private static final String CONTRACT_STAGE = 'Under Contract (PSA)';
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
     * The Negotiation_Status__c every auto-created ACQUISITION Contract Review is seeded with
     * (design collision C3, Acquisition Observations observation 7, 2026-08-14).
     *
     * 🔴 IT IS NOT THE FIELD'S DEFAULT, AND THAT IS THE WHOLE POINT. The field-level default is
     * 'Initial Draft', which after observation 7 belongs to Disposition_PSA ONLY. This constant
     * pairs with ACQUISITION_PSA_RECORD_TYPE the same way 'Pending' pairs with
     * ACQUISITION_NDA_RECORD_TYPE in ensureNda and 'Draft' pairs with ACQUISITION_LOI_RECORD_TYPE
     * in the LOI block: three record-typed children, three seed values this class owns, because
     * Apex DML does not enforce record-type picklist restriction and the platform will happily
     * commit a value the record type does not carry.
     *
     * ⚠ It COINCIDES with the LOI block's seed stage ('Draft') and with nothing else. They are two
     * unrelated values on two different fields that happen to share a word; do not extract a shared
     * constant.
     */
    @TestVisible
    private static final String ACQUISITION_PSA_STATUS = 'Draft';

    /**
     * DeveloperName of the queue that OWNS every auto-created acquisition LOI (2026-08-15).
     * Must match queues/Acquisition.queue-meta.xml, whose file name IS its DeveloperName.
     *
     * ⚠ It is the DeveloperName, never an Id. A hardcoded Id is org-specific and would make this
     * class undeployable to any org but the one it was written against — and would fail as a
     * malformed-Id DML error inside an approval transaction, which is the one failure this block
     * is built to avoid.
     */
    @TestVisible
    private static final String ACQUISITION_QUEUE_DEVELOPER_NAME = 'Acquisition';

    /**
     * TEST SEAM — when non-null, the queue DeveloperName the LOI block resolves instead of
     * ACQUISITION_QUEUE_DEVELOPER_NAME. Exists so a test can drive the REAL selector against a
     * name that does not exist and prove the degraded path, rather than faking the answer.
     * Production never sets it.
     */
    @TestVisible
    private static String queueDeveloperNameOverride;

    /**
     * TEST SEAM — when true, the queue resolution throws before it queries. Exists solely to
     * exercise the residual catch in acquisitionQueueId(), which no ordinary input can reach
     * (a missing queue returns null; it does not throw). Production never sets it.
     */
    @TestVisible
    private static Boolean simulateQueueLookupFailure = false;

    /**
     * The message from the last swallowed queue-resolution failure, or null. In-transaction
     * only — it exists for tests and debugging, exactly like
     * EmailThreadAdopterService.lastRunFailureCodes, and is NOT a monitoring surface.
     */
    @TestVisible
    private static String lastQueueLookupError;

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
        // 🔴 Resolved ONCE for the whole chunk, exactly like the record-type describe above and for
        // the same reason: it is a describe, so it costs no SOQL, but one per record would be 251
        // of them on a bulk stage move for an answer that cannot vary within a transaction.
        Boolean canSeedAcquisitionPsaStatus =
            isActivePicklistValue(Contract_Review__c.Negotiation_Status__c, ACQUISITION_PSA_STATUS);
        List<Contract_Review__c> contractToInsert = new List<Contract_Review__c>();
        for (Id oppId : contractOpps) {
            // ⚠ 'PSA Drafting' is Stage__c, which is a DERIVED PROJECTION — the
            // Contract_Review_Stage_Sync before-save flow recomputes it from
            // Negotiation_Status__c on every save, so this seed is cosmetic and is
            // immediately replaced by the flow's mapping of whatever status this row lands
            // on. It is left exactly as it was: changing it would be a no-op that reads
            // like a fix.
            Contract_Review__c cr = new Contract_Review__c(
                Opportunity__c = oppId, Stage__c = 'PSA Drafting');
            // ── 🔴 SEED THE NEGOTIATION STATUS EXPLICITLY (design collision C3, 2026-08-14) ──
            // THIS INSERT USED TO SET NO STATUS AT ALL and take the FIELD-LEVEL DEFAULT, which is
            // 'Initial Draft'. Observation 7 removes 'Initial Draft' from Acquisition_PSA and
            // replaces the buy-side sequence with Draft -> Negotiation -> Signed -> Executed, so
            // the default is now a value this record type does not carry.
            //
            // 🔴 THAT FAILS SILENTLY, WHICH IS WHY IT HAD TO BE FIXED HERE RATHER THAN LEFT TO THE
            // PLATFORM. Apex DML does not enforce record-type picklist restriction, so the insert
            // COMMITS on the off-set value — no exception, no error, a green deploy. The record is
            // then unusable from birth: its Path renders blank, and
            // RecordStageAdvanceService.CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE has no entry for
            // 'Initial Draft', so Advance Stage refuses on the very first click. Every deal
            // entering 'Under Contract (PSA)' would produce one.
            //
            // ⚠ DO NOT "FIX" THIS BY MOVING THE FIELD-LEVEL DEFAULT. Disposition_PSA still runs on
            // 'Initial Draft' — DispositionStageEntryService seeds it deliberately, and O3 of the
            // requirements doc makes keeping that value ACTIVE a hard stop. The default serves the
            // sell side; the buy side names its own seed here. Exactly the pairing the LOI block
            // below already makes, and its comment states the principle: the right seed stage is
            // this method's responsibility, not the platform's.
            //
            // 🔴 DESCRIBE-GUARDED, AND THE GUARD IS NOT DEFENSIVE POLISH — IT IS DEPLOY ORDERING.
            // Negotiation_Status__c is <restricted>true</restricted>, so writing 'Draft' before the
            // P3-D1 picklist deploy lands throws INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST. This
            // insert runs in an AFTER-UPDATE trigger and shares ONE all-or-none transaction with
            // four sibling children (see the class header, argument (b)), so that throw would not
            // cost a Contract Review — it would roll back the deal driver's own stage change and
            // take the Underwriting and LOI children with it. Unguarded, an Apex deploy that
            // arrived before its picklist deploy would make 'Under Contract (PSA)' unreachable for
            // every deal in the org.
            //
            // When the value is absent the field falls back to its own default, i.e. EXACTLY
            // today's behaviour — the change degrades to the status quo rather than to a new
            // failure. Same shape as the record-type guard three lines below, and the same shape as
            // LeadConvertService's restricted-picklist guards.
            if (canSeedAcquisitionPsaStatus) {
                cr.Negotiation_Status__c = ACQUISITION_PSA_STATUS;
            }
            // 🔴 GUARDED, and the guard was RE-ARGUED for THIS block, not inherited from
            // ensureNda or from the LOI block (D20/W2). See the class header, argument (a)+(b):
            // 'Under Contract (PSA)' has exactly ONE route in and this insert shares an
            // all-or-none transaction with four sibling children. Null here is a legitimate
            // answer.
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
        // pattern as the Contract Review at 'Under Contract (PSA)').
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
            // 🔴 ONE QUERY FOR THE WHOLE CHUNK, and the rule binds harder here than on the
            // describe above because this one IS SOQL: per record it would be 251 queries on a
            // bulk stage move, i.e. past the 100-query governor limit and therefore an
            // UNCATCHABLE LimitException inside the approval transaction. It sits inside the
            // `!loiOpps.isEmpty()` guard, so a chunk entering no LOI stage still costs zero.
            Id acquisitionQueueId = acquisitionQueueId();
            List<LOI__c> loiToInsert = new List<LOI__c>();
            for (Id oppId : loiOpps) {
                // 🔴 THE ACQUISITION QUEUE OWNS THE LOI, EVERY TIME — ownership must be a
                // property of the PROCESS, not of whichever principal happened to trigger the
                // stage entry. The LOI stage is entered by the LOI approval's own field update,
                // so the running user here is the APPROVER; a queue is the only owner that is
                // neither the approver nor any single person, and the Acquisitions team reaches
                // it through one sharing rule rather than through a role hierarchy that grants
                // access upward and so never reached a principal-owned row.
                //
                // ⚠ THE FALLBACK IS THE DEAL'S OWNER, WHICH IS WHAT THIS LINE USED TO BE
                // UNCONDITIONALLY. It is kept, not deleted: when the queue cannot be resolved
                // the alternative is to leave OwnerId unset, and unset means the RUNNING USER —
                // the approver — which is the very defect the deal-owner assignment was added to
                // fix. Degrading to the previous correct-enough answer beats degrading to the
                // original bug. See the class header for why the resolution never throws.
                Id loiOwnerId = (acquisitionQueueId != null)
                    ? acquisitionQueueId
                    : ownerByOpp.get(oppId);
                LOI__c loi = new LOI__c(
                    Opportunity__c = oppId,
                    Property__c = propertyByOpp.get(oppId),
                    OwnerId = loiOwnerId,
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
     * DispositionService.recordTypeIdFor and TestDataFactory.dispositionRecordTypeId, on
     * purpose: three creators of record-typed rows behaving three different ways is its own
     * defect source. (⚠ The disposition one was `onMarketRecordTypeId` until 2026-08-19, when the
     * Sell Meter modal gave the user a record-type CHOICE and it was generalised to take the
     * developer name as a parameter. Same shape, same guard, one argument.)
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
     * DispositionService.recordTypeIdFor (named `onMarketRecordTypeId` until 2026-08-19) and
     * TestDataFactory's two resolvers, on purpose:
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
     * The Id of the `Acquisition` queue when it exists AND is enabled to own LOI__c, or null.
     *
     * Null is a legitimate answer, not an error — the caller then keeps the deal's owner, which
     * is exactly the behaviour this block had before the queue was introduced. See the class
     * header for the full argument; the short version is that this code runs as a READ-ONLY
     * APPROVER inside the approval transaction, so anything that throws here does not cost an
     * LOI, it rolls back the APPROVAL (the ApprovalAuditService/D10 shape).
     *
     * 🔴 IT ASKS QueueSobject, NOT Group, AND THAT IS THE WHOLE POINT OF THE SELECTOR METHOD.
     * A queue that exists but does not list LOI__c in its `queueSobject` set cannot own one, and
     * the platform reports that AT DML TIME — i.e. in the transaction that must not fail. The
     * queue's object list is separate metadata from the queue itself and from this class, and
     * queues/Acquisition.queue-meta.xml carried only Lead and Property__c when this was written,
     * so "queue exists" was never a sufficient licence to write the Id. One query answers both.
     *
     * ⚠ Unlike acquisitionLoiRecordTypeId() this is NOT a describe — it costs ONE SOQL query per
     * invocation. It is called once, inside the `!loiOpps.isEmpty()` guard, never per record.
     *
     * ⚠ The catch is deliberately WIDE (Exception, not QueryException), for the reason
     * ApprovalAuditService was forced to widen its own: a TypeException is not a DmlException and
     * a narrow catch is how D10 escaped and rolled back an approval. It is a floor, not the
     * mechanism — a LimitException is not catchable at all, which is why the query is hoisted out
     * of the loop rather than merely wrapped.
     */
    private static Id acquisitionQueueId() {
        try {
            if (simulateQueueLookupFailure) {
                throw new QueryException('Simulated queue lookup failure (test seam).');
            }
            String developerName = (queueDeveloperNameOverride == null)
                ? ACQUISITION_QUEUE_DEVELOPER_NAME
                : queueDeveloperNameOverride;
            // The object name comes from the describe, not from a string literal, so a future
            // rename of LOI__c is a COMPILE error here rather than a queue lookup that silently
            // stops matching. Same `Schema.SObjectType.LOI__c` form the record-type resolver
            // above uses; it costs no SOQL.
            return QueueGroupSelector.selectQueueIdByDeveloperNameForSObject(
                developerName,
                Schema.SObjectType.LOI__c.getName());
        } catch (Exception e) {
            // Swallowed ON PURPOSE, and recorded rather than ignored so the catch is observable
            // to a test and to a debug session. Rethrowing — or letting this escape — would turn
            // a misconfigured queue into an approval nobody can complete.
            lastQueueLookupError = e.getMessage();
            return null;
        }
    }

    /**
     * The Acquisition_PSA record type Id, or null when it does not exist in this org or is not
     * available to the running user — who, on this path, is the DEAL DRIVER who just advanced the
     * deal from LOI to 'Under Contract (PSA)'.
     *
     * Null is a legitimate answer, not an error: the caller then leaves RecordTypeId unset and the
     * platform applies its own default, which keeps the LOI -> 'Under Contract (PSA)' hop — and
     * therefore the entire
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
     * acquisitionLoiRecordTypeId, DispositionService.recordTypeIdFor (named
     * `onMarketRecordTypeId` until 2026-08-19),
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

    /**
     * Whether `value` is an ACTIVE value of `field`'s picklist right now, in this org.
     *
     * A describe, not a query — it costs no SOQL. Used to guard a write to a
     * `<restricted>true</restricted>` picklist whose target value arrives in a SEPARATE metadata
     * deploy from the Apex that writes it, so that an out-of-order deploy degrades to the field's
     * own default instead of throwing INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST inside a trigger.
     * Same shape and same purpose as LeadConvertService's restricted-picklist guards.
     *
     * 🔴 IT ASKS THE FIELD, NOT THE RECORD TYPE, AND THAT LIMIT MUST BE UNDERSTOOD BEFORE ANYONE
     * REUSES IT. getPicklistValues() returns the FIELD's value set; record-type availability is a
     * different question with a different (and far more expensive, UI-API-only) answer. So this
     * guard proves "the platform will accept this write", never "this value belongs on this record
     * type". Pairing the value with the right record type is still the caller's job — which is
     * exactly the responsibility the C3 comment at the call site claims. A guard that could answer
     * the record-type question would make that comment unnecessary; this one does not.
     *
     * ⚠ `isActive()` matters as much as membership. A DEACTIVATED value is still returned by
     * getPicklistValues(), so a plain name scan would keep writing a value the field has retired —
     * which is the exact state observation 5 leaves LOI__c.Stage__c's four old values in.
     */
    private static Boolean isActivePicklistValue(Schema.SObjectField field, String value) {
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive() && value.equals(entry.getValue())) {
                return true;
            }
        }
        return false;
    }
}