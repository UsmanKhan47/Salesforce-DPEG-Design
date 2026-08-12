/**
 * @description Tests RecordStageAdvanceService — the generic stage-advance service behind the
 * "advance stage" quick action on NDA__c, LOI__c, Contract_Review__c, Underwriting__c,
 * Construction_Feasibility_Review__c, Development_Feasibility_Review__c and, since 2026-08-12,
 * Transaction__c.
 *
 * ── ✅ Transaction__c COVERAGE ADDED (2026-08-12, live UI testing fix set) ────
 * transactionWalksOpenContractThroughToClosedWon pins the user-confirmed sequence (picklist order,
 * NOT the Path step-text's implied order — see TRANSACTION_NEXT_STAGE's own header for why those
 * two readings disagree). transactionAdvanceToIsStructurallyUnreachable is the falsifier for the
 * EMPTY explicit-target allow-list: Transaction__c's path is a straight line with no branch, off-
 * ramp or loop, so advanceTo() must refuse every target, including a real, valid stage value
 * ('Post-Closing') — the sharper failure mode than a nonsense string, because it proves the refusal
 * comes from the allow-list being empty rather than the target being unrecognised.
 * transactionGateDeniesABareUserAndGrantsAPermissionSetHolder is the one gate test in this class
 * that needs NO cache-seeding trick: TRANSACTION_STAGE_ACTIONS is Transaction__c's gate and it never
 * loads the record (single sequence — see gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject
 * below), so a bare user's OWD/CRUD on Transaction__c is never even reached and a real
 * System.runAs proof is possible end to end. The gate's OWN membership-vs-authorization argument,
 * group expansion and admin-bypass proofs live in TransactionActionPermissionServiceTest — this
 * class only proves the DISPATCH (gateFor -> TRANSACTION_STAGE_ACTIONS ->
 * TransactionActionPermissionService) is wired, not the gate's internals.
 *
 * ── ⚠ REWRITTEN 2026-08-12 FOR THE CUSTOM-PERMISSION MIGRATION ───────────────
 * TransactionActionPermissionService no longer delegates to LeadActionPermissionService — it now
 * owns its own transaction-scoped cache, exactly like OpportunityActionPermissionService and
 * DispositionActionPermissionService. Every place in this class that used to clear or seed
 * LeadActionPermissionService's cache for the Transaction gate (adminPassesTheGateOnEveryObject,
 * transactionGateDeniesABareUserAndGrantsAPermissionSetHolder,
 * gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject) now targets
 * TransactionActionPermissionService directly. The NDA__c / LOI__c / Contract_Review__c gate-dispatch
 * tests (theGateIsResolvedPerRecordTypeNotPerObject and its siblings) were UNCHANGED by this
 * migration — they seed OpportunityActionPermissionService.cachedHasDealActionAccess /
 * DispositionActionPermissionService.cachedHasDispositionActionAccess directly and always did, never
 * through the retired User field.
 *
 * ── HOW THE STAGE MAPS ARE PINNED ────────────────────────────────────────────
 * Each object gets a WALK test that calls advance() repeatedly until it is refused and asserts the
 * EXACT, ORDERED list of returned messages. Because advance() names its target in the message
 * ('LOI moved to Sent.'), that one assertion pins the whole map verbatim — every hop, in order, plus
 * the terminal refusal — without a single re-query and without reaching into private state. Adding,
 * removing or reordering a hop reds the walk immediately and shows exactly where.
 *
 * Since 2026-08-09 NDA__c gets TWO walks, one per record type, for the reason below — and since
 * Tranche 3B the same day, so does LOI__c.
 *
 * ── ⚠ THE TWO MULTI-RECORD-TYPE OBJECTS ARE NOT THE SAME SHAPE, AND THE TESTS DIFFER ──
 * NDA__c's two value sets OVERLAP ('Sent', 'Signed'), so the current stage alone cannot identify
 * the sequence — sharedSentStatusAdvancesDifferentlyPerRecordType is the proof.
 * LOI__c's are FULLY DISJOINT, so no equivalent test is possible or needed; what LOI__c has
 * instead is the ALLOW-LIST leak in BOTH directions
 * (dispositionLoiRefusesTheAcquisitionExplicitTargets /
 * acquisitionLoiRefusesADispositionStageAsAnExplicitTarget), because its acquisition record type
 * is the one object in the repo that shipped with an object-level explicit-target set.
 *
 * ── 🔴 AND THE THIRD SHAPE: A LOOP (Tranche 3B close-out) ────────────────────
 * dispositionLoiAcceptsTheNegotiationLoopTargets. The disposition LOI is neither a line (like the
 * acquisition NDA), nor a branch (like the acquisition LOI at 'Sent'), nor an off-ramp (like the
 * disposition NDA's 'Declined') — it is a CYCLE: 'Countered by DPEG' <-> 'Counter Received from
 * Buyer', because the document says the negotiation "goes round until both sides are agreed". A
 * Map<String, String> holds one value per key, so the BACK-edge is provably inexpressible in
 * LOI_DISPOSITION_NEXT_STAGE — the key already maps forward to 'Executed'. That test walks the
 * cycle and then keeps advancing to 'Executed', which is what falsifies the tempting wrong build:
 * editing the NEXT_STAGE map to point 'Counter Received from Buyer' back at 'Countered by DPEG'
 * would make advance() loop forever and the sell-side path could never terminate.
 *
 * 🔴 CONSEQUENCE OF LOI__c BECOMING MULTI-RECORD-TYPE, worth knowing before editing any gate test:
 * resolving an LOI's gate now LOADS the row, so a bare Standard User cannot reach the gate at all
 * on an OWD-Private LOI. bareUserIsDeniedAndNothingIsWritten therefore moved to Underwriting__c —
 * see its own header, and note gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject moved its
 * zero-query probe there for the same reason.
 *
 * ── 🔴 THE MOST IMPORTANT TEST IN THIS CLASS ─────────────────────────────────
 * underwritingNeverReachesApprovedFromInProgress. 'Approved' on Underwriting__c is owned by the
 * PRINCIPAL APPROVAL PROCESS, and a naive "same as the other five objects" map would put it one
 * button-click away and bypass the approval entirely. That test is falsifiable in both directions:
 * it asserts the call is REFUSED, that the stage in the database is STILL 'In Progress' (so a write
 * that happened before the refusal would red it), and that the message names the real route.
 *
 * ── 🔴 THE MOST IMPORTANT *NEW* TEST (Tranche 3A) ────────────────────────────
 * acquisitionNdaRefusesTheDispositionOnlyDeclinedTarget. Record-type picklist restrictions are
 * enforced by the UI ONLY — Apex DML does not enforce them — so making only the NEXT-STAGE map
 * record-type-aware would leave 'Declined' writable onto an acquisition NDA through advanceTo. That
 * version of the change compiles, passes every walk test, and is a security hole. This test is the
 * falsifier, and dispositionNdaAcceptsDeclinedAsAnExplicitTarget is its complement: without the
 * pair, a refusal could pass simply because 'Declined' was configured nowhere at all.
 *
 * sharedSentStatusAdvancesDifferentlyPerRecordType is the second half of the argument. Both NDA
 * record types carry 'Sent', and from it the acquisition NDA goes to 'Received' while the
 * disposition NDA goes to 'Signed'. One object-level map cannot express that at any price.
 *
 * ── 🔴 AND THE THIRD PER-RECORD-TYPE AXIS: THE PERMISSION GATE ───────────────
 * theGateIsResolvedPerRecordTypeNotPerObject. Since 2026-08-09 the gate lives on StageTypeConfig
 * alongside nextStage and explicitTargets: Acquisition_NDA answers to DEAL_DRIVER and
 * Disposition_NDA to DISPOSITION_DRIVER. Held at object level, an acquisitions deal driver could
 * drive a SALE's NDA. That test pre-seeds the two permission services' caches with OPPOSITE
 * answers — and asserts BOTH polarities, so a hardcoded constant cannot pass — because the honest
 * alternative (two real personas under System.runAs) cannot work on an OWD-Private object whose
 * selector would throw before the gate was ever consulted. Whether each gate is itself correct is
 * DispositionActionPermissionServiceTest's and OpportunityActionPermissionServiceTest's job, and
 * they do use real runAs.
 *
 * ── ✅ Contract_Review__c GATE COVERAGE CLOSED (Tranche 3C, gap fill) ─────────
 * This class had ZERO Contract_Review__c coverage before this pass — handed back explicitly by the
 * 3C developer as a known, deliberate gap: "compile-verified only." Closed with
 * acquisitionPsaWalksInitialDraftToExecuted / dispositionPsaWalksInitialDraftToExecuted (the walk,
 * on both record types), contractReviewGateIsResolvedPerRecordTypeNotPerObject (the falsifier for
 * the gate split — see its own header for why the walk tests alone cannot catch a reverted gate),
 * and Contract_Review__c's addition to adminPassesTheGateOnEveryObject and
 * gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject. Unlike NDA__c and LOI__c,
 * Contract_Review__c's two record types share ONE sequence by reference (CONTRACT_REVIEW_NEXT_STAGE)
 * and differ ONLY in the gate — so its walk tests are expected to be byte-identical, and only the
 * gate test can tell a correct build apart from a regression to the old single-gate config.
 *
 * ── ⚠ FIXTURES: WHY THE RECORD TYPE IS STAMPED EXPLICITLY AND ASSERTED FIRST ──
 * Every record-type test stamps RecordTypeId itself and then READS IT BACK before doing anything
 * else (insertNdaOnRecordType). Two reasons, both learned on this branch:
 *   - relying on the profile DEFAULT record type would make these tests assert org state (gate
 *     T-A2) instead of the service;
 *   - D13 residual 1 measured getRecordTypeInfosByDeveloperName() returning a real Id while the
 *     INSERTED ROW still carried RecordTypeId = null. Without the read-back that shows up as a
 *     baffling message-list mismatch; with it, the failure says exactly what happened.
 *
 * 🔴 THESE TESTS DO NOT COMPILE OR PASS UNTIL objects/NDA__c/recordTypes/, objects/LOI__c/
 * recordTypes/, objects/Contract_Review__c/recordTypes/ AND the new Status__c / Stage__c /
 * Negotiation_Status__c values ARE DEPLOYED. A custom object with zero record types has no
 * RecordTypeId field at all, so `nda.RecordTypeId = x`, `loi.RecordTypeId = x` and
 * `cr.RecordTypeId = x` are COMPILE dependencies, not runtime ones (measured on usman-dpeg
 * 2026-08-09: NDA__c described with only Master and no RecordTypeId). That is the
 * metadata-before-Apex ordering the design mandates (§6 T1 before T6) and it is not a defect here.
 * Do NOT guard, skip or soften these assertions to obtain a green suite — the precedent is
 * TestDataFactoryTest.createDisposition_defaultOverload_stampsOnMarketRecordType, which is
 * deliberately red for exactly this reason.
 *
 * ── KNOWN UNTESTABLE BRANCH: a real record type with no configured sequence ──
 * sequenceKeyFor() REFUSES (rather than silently defaulting) when a row sits on a named record type
 * absent from the config. It cannot be reached from a test: every NDA record type that exists is
 * configured, and the branch is unreachable on the five objects that carry one sequence. Creating a
 * throwaway record type from Apex is impossible, and a @TestVisible seam able to redirect the
 * sequence lookup is the same class of risk this class already rejected for setStage. It becomes
 * testable the day a third NDA record type exists; add the test then.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * No 251-record scenario applies. advance() is a per-transaction-singleton @AuraEnabled operation
 * invoked once per quick-action click — one record, one selector read, one update, no loop over
 * records and no collection DML. Same shape and same exemption as StageAdvanceServiceTest and
 * OpportunityActionPermissionServiceTest (.claude/rules/bulk-test-rule.md, per-transaction-singleton
 * exemption). A 251-record test here would exercise no additional code path.
 *
 * ── 🔴 KNOWN, DELIBERATE COVERAGE GAP: setStage's DmlException catch ─────────
 * That catch exists to surface a validation rule's own message to the user, which is the entire
 * reason this program routes stage writes through Apex. It is currently UNCOVERED, and the reason is
 * a fact about the org rather than a shortcut:
 *
 *   THERE IS NO WAY TO MAKE ONE OF THESE SIX UPDATES FAIL TODAY. Verified 2026-08-04, re-verified
 *   2026-08-09 (still zero validationRules directories across all six):
 *     - objects/<each>/validationRules/ does not exist on ANY of the six (design decision D6
 *       defers rule authoring to a follow-on, so this program ships the actions first);
 *     - all six Opportunity validation rules are ISCHANGED(StageName)-scoped, so the mirror write
 *       Underwriting_Opp_Sync makes on the parent cannot trip one;
 *     - the update sends only Id + the stage field, so no untouched required field or lookup is
 *       re-validated;
 *     - the record cannot be deleted between the selector read and the update — they are one call;
 *     - MIXED_DML_OPERATION was TRIED as a synthetic block and MEASURED NOT TO FIRE on this org,
 *       both before and inside Test.startTest(): `insert <User>` followed by the non-setup update
 *       simply succeeds. Do not re-attempt it.
 *   The remaining option was a @TestVisible seam that REDIRECTS THE WRITE to an invalid value.
 *   That was rejected: a test seam able to change what gets written to a stage field is a worse
 *   risk than one uncovered statement, and it would prove nothing a real rule will not prove.
 *
 * ⇒ WHEN THE FIRST VALIDATION RULE ON ANY OF THE SIX LANDS, ADD ITS TEST HERE. Assert that the
 *   rule's own errorMessage reaches the caller verbatim — that is the behaviour the whole
 *   Apex-not-LDS write decision was made to obtain, and until then it is unproven.
 *
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls
 * @see force-app/main/default/classes/StageAdvanceServiceTest.cls (the Opportunity sibling)
 * @author Salesforce Developer
 */
@isTest
private class RecordStageAdvanceServiceTest {

    /**
     * One deal with exactly one of each stage-controlled child. The auto-created NDA is deleted
     * first: OpportunityReviewService.ensureNda opens one NDA on every Opportunity insert, so
     * without this there would be two and "the NDA" would be ambiguous.
     */
    @TestSetup
    static void setupTestData() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        delete [SELECT Id FROM NDA__c WHERE Opportunity__c = :deal.Id];
        TestDataFactory.createNda(deal.Id, true);
        TestDataFactory.createLoi(deal.Id, true);
        TestDataFactory.createUnderwriting(deal.Id, true);
        TestDataFactory.createConstructionReview(deal.Id, null, true);
        TestDataFactory.createDevelopmentReview(deal.Id, null, true);
        // Plain (guarded, no explicit record type) Contract Review — the migration-window fixture,
        // same role as the plain nda()/loi() fixtures above. 'New' is the Opportunity stage this
        // factory seeds, which per createOpportunities' own header does not cascade a Contract
        // Review on insert, so this is not a duplicate of any auto-created row.
        TestDataFactory.createContractReview(deal.Id, true);
    }

    /**
     * Counterparty name carried by every NDA a record-type test builds for itself. It exists purely
     * so nda() can exclude them — NDA__c has no natural ordering key here, so a bare `LIMIT 1`
     * would silently become ambiguous the moment a method inserts a second NDA.
     */
    private static final String RT_FIXTURE_TAG = 'RT Fixture';

    private static final String RT_ACQUISITION_NDA = 'Acquisition_NDA';
    private static final String RT_DISPOSITION_NDA = 'Disposition_NDA';

    private static Id dealId() {
        return [SELECT Id FROM Opportunity LIMIT 1].Id;
    }

    /** The @TestSetup NDA, never one of the record-type fixtures. */
    private static NDA__c nda() {
        String fixturePrefix = RT_FIXTURE_TAG + '%';
        return [
            SELECT Id, Status__c
            FROM NDA__c
            WHERE (NOT Counterparty_Name__c LIKE :fixturePrefix)
            LIMIT 1
        ];
    }

    /**
     * Resolves an NDA record type Id by developer name.
     *
     * ⚠ Constant-first is irrelevant here, but the CASE is not: getRecordTypeInfosByDeveloperName()
     * returns a case-SENSITIVE map, so a mis-cased name yields null rather than a near-match. The
     * assertion below turns that into a named failure instead of a NullPointerException fifteen
     * lines later.
     */
    private static Id ndaRecordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.NDA__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'The NDA__c record type "' + developerName + '" does not exist in this org. Tranche 3A '
            + 'metadata (objects/NDA__c/recordTypes/) must be deployed before this suite can run — '
            + 'that ordering is the design\'s T1-before-T6, not a defect in the test. Available: '
            + Schema.SObjectType.NDA__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }

    /**
     * An NDA stamped with a specific record type and status, with the stamp READ BACK before the
     * caller is allowed to proceed.
     *
     * 🔴 The read-back is the point. D13 residual 1 measured an inserted row carrying
     * RecordTypeId = null even though the describe had returned a real Id — under which condition
     * every record-type test in this class would fail with a confusing message-list diff instead of
     * naming the real cause.
     *
     * ⚠ The disposition fixture is deliberately parented to NOTHING. A realistic Disposition_NDA
     * hangs off a Disposition__c, but building one drags Tranche 2's own record-type stamp into a
     * test about stage SEQUENCES, where its known-fragile isAvailable() guard could red this suite
     * for an unrelated reason. The service reads Status__c and RecordTypeId and nothing else, so the
     * parent is not part of what is under test.
     */
    private static NDA__c insertNdaOnRecordType(String recordTypeDeveloperName, String status) {
        Id expectedRecordTypeId = ndaRecordTypeId(recordTypeDeveloperName);
        Boolean isAcquisition = RT_ACQUISITION_NDA.equals(recordTypeDeveloperName);

        NDA__c nda = TestDataFactory.createNdas(1, isAcquisition ? dealId() : null, false)[0];
        nda.Counterparty_Name__c = RT_FIXTURE_TAG + ' ' + recordTypeDeveloperName;
        nda.RecordTypeId = expectedRecordTypeId;
        nda.Status__c = status;
        try {
            insert nda;
        } catch (DmlException e) {
            // ⚠ MEASURED 2026-08-09 on usman-dpeg: an UNGUARDED RecordTypeId stamp does NOT fail
            // silently the way TestDataFactory's isAvailable()-guarded one does — it throws
            // INVALID_CROSS_REFERENCE_KEY "this ID value isn't valid for the user". The record type
            // resolves to a real Id and is still not assignable, which is post-deploy gate T-A1
            // (profile record-type assignment) not having run. Caught here only so the failure
            // NAMES itself instead of arriving as a raw DmlException from a helper; the platform
            // message is passed through in full.
            Assert.fail('PRECONDITION FAILED, not a service defect: could not insert an NDA on the '
                + recordTypeDeveloperName + ' record type. INVALID_CROSS_REFERENCE_KEY here means '
                + 'the record type exists but is assigned to no profile — post-deploy gate T-A1. '
                + 'Every record-type assertion in this class is blocked until that runs, and none '
                + 'of them may be softened to go green. Platform message: ' + e.getMessage());
        }

        NDA__c stored = [SELECT Id, Status__c, RecordTypeId FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual(expectedRecordTypeId, stored.RecordTypeId,
            'PRECONDITION FAILED, not a service defect: the ' + recordTypeDeveloperName
            + ' record type did not land on the inserted row. A stamped RecordTypeId that reads '
            + 'back null means the record type is not available to the running user — see D13 '
            + 'residual 1 and post-deploy gate T-A1. Every record-type assertion below is '
            + 'meaningless until this passes.');
        Assert.areEqual(status, stored.Status__c,
            'PRECONDITION FAILED: the fixture did not start at "' + status + '". A missing Tranche '
            + '3A picklist value throws INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST on the insert above '
            + 'rather than reaching here, so this catches the quieter case — a before-save '
            + 'automation rewriting the status.');
        return stored;
    }

    /** The @TestSetup LOI, never one of the record-type fixtures (which carry no Opportunity). */
    private static LOI__c loi() {
        return [SELECT Id, Stage__c FROM LOI__c WHERE Opportunity__c != NULL LIMIT 1];
    }

    private static final String RT_ACQUISITION_LOI = 'Acquisition_LOI';
    private static final String RT_DISPOSITION_LOI = 'Disposition_LOI';

    /** Resolves an LOI record type Id by developer name. Same case-sensitivity note as the NDA one. */
    private static Id loiRecordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'The LOI__c record type "' + developerName + '" does not exist in this org. Tranche 3B '
            + 'metadata (objects/LOI__c/recordTypes/) must be deployed before this suite can run — '
            + 'that ordering is the design\'s metadata-before-Apex, not a defect in the test. '
            + 'Available: '
            + Schema.SObjectType.LOI__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }

    /**
     * An LOI stamped with a specific record type and stage, with the stamp READ BACK before the
     * caller is allowed to proceed. Exact counterpart of insertNdaOnRecordType — see that method
     * for why the read-back matters (D13 residual 1) and why the failures are worded as
     * PRECONDITIONS naming post-deploy gate T-A1.
     *
     * ⚠ Both fixtures are parented to NOTHING. The service reads Stage__c and RecordTypeId and
     * nothing else, so neither the Opportunity nor the Disposition is part of what is under test —
     * and building a Disposition__c here would drag Tranche 2's own known-fragile isAvailable()
     * record-type guard into a test about stage SEQUENCES. It also keeps loi() unambiguous, since
     * LOI__c has no natural ordering key.
     */
    private static LOI__c insertLoiOnRecordType(String recordTypeDeveloperName, String stage) {
        Id expectedRecordTypeId = loiRecordTypeId(recordTypeDeveloperName);

        LOI__c loi = TestDataFactory.createLois(1, null, recordTypeDeveloperName, false)[0];
        loi.RecordTypeId = expectedRecordTypeId;
        loi.Stage__c = stage;
        try {
            insert loi;
        } catch (DmlException e) {
            // ⚠ MEASURED 2026-08-09 on usman-dpeg (on NDA__c, same mechanism): an UNGUARDED
            // RecordTypeId stamp does NOT fail silently the way TestDataFactory's
            // isAvailable()-guarded one does — it throws INVALID_CROSS_REFERENCE_KEY "this ID
            // value isn't valid for the user". Caught here only so the failure NAMES itself.
            Assert.fail('PRECONDITION FAILED, not a service defect: could not insert an LOI on the '
                + recordTypeDeveloperName + ' record type. INVALID_CROSS_REFERENCE_KEY here means '
                + 'the record type exists but is assigned to no profile — post-deploy gate T-A1. '
                + 'INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST means the Tranche 3B Stage__c values '
                + 'have not deployed. Neither may be softened to go green. Platform message: '
                + e.getMessage());
        }

        LOI__c stored = [SELECT Id, Stage__c, RecordTypeId FROM LOI__c WHERE Id = :loi.Id];
        Assert.areEqual(expectedRecordTypeId, stored.RecordTypeId,
            'PRECONDITION FAILED, not a service defect: the ' + recordTypeDeveloperName
            + ' record type did not land on the inserted row. A stamped RecordTypeId that reads '
            + 'back null means the record type is not available to the running user — see D13 '
            + 'residual 1 and post-deploy gate T-A1. Every record-type assertion below is '
            + 'meaningless until this passes.');
        Assert.areEqual(stage, stored.Stage__c,
            'PRECONDITION FAILED: the fixture did not start at "' + stage + '".');
        return stored;
    }

    /** The @TestSetup Contract Review, never one of the record-type fixtures (which carry no Opportunity). */
    private static Contract_Review__c contractReview() {
        return [SELECT Id, Negotiation_Status__c FROM Contract_Review__c LIMIT 1];
    }

    private static final String RT_ACQUISITION_PSA = 'Acquisition_PSA';
    private static final String RT_DISPOSITION_PSA = 'Disposition_PSA';

    /** Resolves a Contract_Review__c record type Id by developer name. Same case-sensitivity note as the NDA / LOI ones. */
    private static Id contractReviewRecordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'The Contract_Review__c record type "' + developerName + '" does not exist in this '
            + 'org. Tranche 3C metadata (objects/Contract_Review__c/recordTypes/) must be deployed '
            + 'before this suite can run — that ordering is the design\'s metadata-before-Apex, not '
            + 'a defect in the test. Available: '
            + Schema.SObjectType.Contract_Review__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }

    /**
     * A Contract Review stamped with a specific record type and Negotiation_Status__c, with the
     * stamp READ BACK before the caller is allowed to proceed. Exact counterpart of
     * insertNdaOnRecordType / insertLoiOnRecordType — see insertNdaOnRecordType's header for why
     * the read-back matters (D13 residual 1) and why the failures are worded as PRECONDITIONS
     * naming post-deploy gate T-A1.
     *
     * ⚠ Parented to NOTHING, same reasoning as the NDA/LOI fixtures: the service reads only
     * Negotiation_Status__c and RecordTypeId, so neither Opportunity__c nor Disposition__c is part
     * of what is under test here, and attaching either would drag an unrelated module's own guard
     * into a test about stage SEQUENCES and the GATE.
     *
     * ⚠ Uses TestDataFactory's record-type-aware overload directly (unlike insertNdaOnRecordType,
     * which deliberately calls the plain 3-arg one) because — unlike the NDA seed — nothing else
     * in the row varies by record type here; both PSA types share one Negotiation_Status__c value
     * set by design (D16.3), so passing recordTypeDeveloperName straight through costs nothing.
     */
    private static Contract_Review__c insertContractReviewOnRecordType(
        String recordTypeDeveloperName,
        String negotiationStatus
    ) {
        Id expectedRecordTypeId = contractReviewRecordTypeId(recordTypeDeveloperName);

        Contract_Review__c cr =
            TestDataFactory.createContractReviews(1, null, recordTypeDeveloperName, false)[0];
        cr.RecordTypeId = expectedRecordTypeId;
        cr.Negotiation_Status__c = negotiationStatus;
        try {
            insert cr;
        } catch (DmlException e) {
            // ⚠ MEASURED 2026-08-09 on usman-dpeg, on NDA__c and LOI__c — same mechanism applies
            // here: an UNGUARDED RecordTypeId stamp does NOT fail silently the way TestDataFactory's
            // isAvailable()-guarded one does — it throws INVALID_CROSS_REFERENCE_KEY "this ID value
            // isn't valid for the user". Caught here only so the failure NAMES itself instead of
            // arriving as a raw DmlException from a helper; the platform message is passed through
            // in full.
            Assert.fail('PRECONDITION FAILED, not a service defect: could not insert a Contract '
                + 'Review on the ' + recordTypeDeveloperName + ' record type. '
                + 'INVALID_CROSS_REFERENCE_KEY here means the record type exists but is assigned to '
                + 'no profile — post-deploy gate T-A1. Every record-type assertion in this class is '
                + 'blocked until that runs, and none of them may be softened to go green. Platform '
                + 'message: ' + e.getMessage());
        }

        Contract_Review__c stored = [
            SELECT Id, Negotiation_Status__c, RecordTypeId
            FROM Contract_Review__c
            WHERE Id = :cr.Id
        ];
        Assert.areEqual(expectedRecordTypeId, stored.RecordTypeId,
            'PRECONDITION FAILED, not a service defect: the ' + recordTypeDeveloperName
            + ' record type did not land on the inserted row. A stamped RecordTypeId that reads '
            + 'back null means the record type is not available to the running user — see D13 '
            + 'residual 1 and post-deploy gate T-A1. Every record-type assertion below is '
            + 'meaningless until this passes.');
        Assert.areEqual(negotiationStatus, stored.Negotiation_Status__c,
            'PRECONDITION FAILED: the fixture did not start at "' + negotiationStatus + '".');
        return stored;
    }

    private static Underwriting__c underwriting() {
        return [SELECT Id, Stage__c FROM Underwriting__c LIMIT 1];
    }

    private static Construction_Feasibility_Review__c constructionReview() {
        return [SELECT Id, Stage__c FROM Construction_Feasibility_Review__c LIMIT 1];
    }

    private static Development_Feasibility_Review__c developmentReview() {
        return [SELECT Id, Stage__c FROM Development_Feasibility_Review__c LIMIT 1];
    }

    /**
     * Inserts a standalone Transaction__c at 'Open Contract' with the Day-0 fan-out SUPPRESSED
     * (Contract_Executed_Date__c = null — same technique TransactionSelectorTest uses), so this
     * class's stage-map and gate tests are not coupled to TaskFanoutService's async side effects.
     * Parented to nothing: RecordStageAdvanceService reads only Id and Stage__c for this object
     * (selectStageRequiredById's field list is deliberately minimal), so neither Opportunity__c nor
     * Property__c is part of what is under test here — same reasoning as insertNdaOnRecordType /
     * insertLoiOnRecordType parenting to nothing.
     */
    private static Transaction__c insertTransaction() {
        Transaction__c txn = TestDataFactory.createTransaction(null, null, false);
        txn.Contract_Executed_Date__c = null;
        insert txn;
        return txn;
    }

    /**
     * Advances a record until the service refuses, returning every confirmation message in order
     * followed by the refusal prefixed 'BLOCKED: '. The refusal is the terminator, so a map with a
     * cycle fails loudly rather than looping.
     */
    private static List<String> advanceUntilBlocked(Id recordId) {
        List<String> messages = new List<String>();
        for (Integer i = 0; i < 12; i++) {
            try {
                messages.add(RecordStageAdvanceService.advance(recordId));
            } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
                messages.add('BLOCKED: ' + e.getMessage());
                return messages;
            }
        }
        Assert.fail('advance() never refused after 12 hops — the stage map has a cycle: ' + messages);
        return messages;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // STAGE MAPS — one walk per object, pinning every hop verbatim
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void acquisitionNdaWalksPendingThroughReceivedToSigned() {
        // ⚠ NDA__c is one of the two objects whose stage field is not Stage__c (Status__c here,
        // Negotiation_Status__c on Contract_Review__c). If the config ever hardcoded Stage__c this
        // walk would fail on the very first hop.
        //
        // 'Received' was INSERTED between 'Sent' and 'Signed' by decision D14.1. The four-hop shape
        // is the whole acquisition half of Tranche 3A, so this walk is where a regression to the
        // old three-state map would surface.
        Id ndaId = insertNdaOnRecordType(RT_ACQUISITION_NDA, 'Pending').Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(ndaId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'NDA moved to Sent.',
                'NDA moved to Received.',
                'NDA moved to Signed.',
                'BLOCKED: There is no next step available from the Signed stage.'
            },
            messages,
            'The Acquisition_NDA map must be exactly Pending -> Sent -> Received -> Signed (D14.1), '
            + 'with Signed terminal');
        Assert.areEqual('Signed', [SELECT Status__c FROM NDA__c WHERE Id = :ndaId].Status__c,
            'The walk must leave the NDA at its terminal status');
    }

    @isTest
    static void dispositionNdaWalksNotSentToSigned() {
        // The disposition sequence is SHORTER and starts on a value the acquisition record type
        // does not carry at all ('Not Sent'). If the service fell back to the acquisition map, the
        // very first hop would be refused with "no next step available from the Not Sent stage" —
        // so this walk fails LOUDLY rather than subtly if record-type resolution breaks.
        Id ndaId = insertNdaOnRecordType(RT_DISPOSITION_NDA, 'Not Sent').Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(ndaId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'NDA moved to Sent.',
                'NDA moved to Signed.',
                'BLOCKED: There is no next step available from the Signed stage.'
            },
            messages,
            'The Disposition_NDA map must be exactly Not Sent -> Sent -> Signed. There is no '
            + '"Received" step on a sale — DPEG issues the NDA, so it never comes back TO us as a '
            + 'separate milestone');
        Assert.areEqual('Signed', [SELECT Status__c FROM NDA__c WHERE Id = :ndaId].Status__c,
            'The walk must leave the NDA at its terminal status');
    }

    @isTest
    static void sharedSentStatusAdvancesDifferentlyPerRecordType() {
        // 🔴 THE ARGUMENT FOR THE WHOLE CHANGE, IN ONE TEST.
        // 'Sent' is present on BOTH NDA record types, so the current stage alone cannot identify the
        // sequence. From it an acquisition NDA must reach 'Received' and a disposition NDA must
        // reach 'Signed'. No Map<SObjectType, ...> can produce two answers for one key, so this test
        // is unpassable by any object-level design — which is exactly what makes it worth having.
        Id acquisitionId = insertNdaOnRecordType(RT_ACQUISITION_NDA, 'Sent').Id;
        Id dispositionId = insertNdaOnRecordType(RT_DISPOSITION_NDA, 'Sent').Id;

        Test.startTest();
        String acquisitionMessage = RecordStageAdvanceService.advance(acquisitionId);
        String dispositionMessage = RecordStageAdvanceService.advance(dispositionId);
        Test.stopTest();

        Assert.areEqual('NDA moved to Received.', acquisitionMessage,
            'From Sent, an Acquisition_NDA advances to Received');
        Assert.areEqual('NDA moved to Signed.', dispositionMessage,
            'From the SAME status, a Disposition_NDA advances to Signed instead');

        Set<Id> ndaIds = new Set<Id>{ acquisitionId, dispositionId };
        Map<Id, NDA__c> stored = new Map<Id, NDA__c>([
            SELECT Id, Status__c FROM NDA__c WHERE Id IN :ndaIds
        ]);
        Assert.areEqual('Received', stored.get(acquisitionId).Status__c,
            'and the acquisition NDA must actually be written to Received');
        Assert.areEqual('Signed', stored.get(dispositionId).Status__c,
            'and the disposition NDA must actually be written to Signed');
    }

    @isTest
    static void ndaWithNoExplicitRecordTypeUsesTheAcquisitionSequence() {
        // THE MIGRATION-WINDOW GUARANTEE. Between the record-type deploy (T1) and the row migration
        // (GATE T-B) every live NDA sits on Master; before T1 it has no RecordTypeId at all. Both
        // states must keep advancing on the ACQUISITION sequence, because every NDA in the org today
        // is acquisition-side by construction.
        //
        // ⚠ The @TestSetup NDA is created without a RecordTypeId, so what this asserts depends on
        // org state, deliberately and usefully:
        //   - before T1 / on Master  -> the service's null-and-Master fallback is what answers;
        //   - after gate T-A2        -> the profile DEFAULT answers, and T-A2 sets it to
        //                               Acquisition_NDA. A red here would mean T-A2 was done wrong.
        // Either way the required behaviour is identical, which is why one test covers both.
        Id ndaId = nda().Id;

        Test.startTest();
        String message = RecordStageAdvanceService.advance(ndaId);
        Test.stopTest();

        Assert.areEqual('NDA moved to Sent.', message,
            'An NDA with no explicit record type must follow the acquisition sequence');
        Assert.areEqual('Sent', [SELECT Status__c FROM NDA__c WHERE Id = :ndaId].Status__c,
            'and the write must actually happen — the fallback is a working path, not a refusal');
    }

    @isTest
    static void loiWalksDraftToCompleted() {
        // The @TestSetup LOI, which TestDataFactory now stamps Acquisition_LOI. This is therefore
        // ALSO the migration-window guarantee for LOI__c: pre-T1 (no RecordTypeId field), or on
        // Master, or once T-A2 sets the profile default, the acquisition sequence must answer —
        // the direct counterpart of ndaWithNoExplicitRecordTypeUsesTheAcquisitionSequence.
        Id loiId = loi().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(loiId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'LOI moved to Prepare/Review.',
                'LOI moved to Sent.',
                'LOI moved to Counter.',
                'LOI moved to Completed.',
                'BLOCKED: There is no next step available from the Completed stage.'
            },
            messages,
            'The Acquisition_LOI map must be exactly Draft -> Prepare/Review -> Sent -> Counter -> '
            + 'Completed, UNCHANGED by Tranche 3B. Note Prepare/Review carries a literal slash — a '
            + 'value that must never be URL-encoded in Apex');
        Assert.areEqual('Completed', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'The walk must leave the LOI at its terminal stage');
    }

    @isTest
    static void dispositionLoiWalksReceivedToExecuted() {
        // The sell-side sequence is a DIFFERENT LENGTH and shares NOT ONE VALUE with the
        // acquisition one — it starts at 'Received', which the acquisition record type does not
        // carry at all. So if record-type resolution broke and this fell back to the acquisition
        // map, the very first hop would be refused with "no next step available from the Received
        // stage" rather than producing a subtly wrong walk.
        Id loiId = insertLoiOnRecordType(RT_DISPOSITION_LOI, 'Received').Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(loiId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'LOI moved to Under Review.',
                'LOI moved to Countered by DPEG.',
                'LOI moved to Counter Received from Buyer.',
                'LOI moved to Executed.',
                'BLOCKED: There is no next step available from the Executed stage.'
            },
            messages,
            'The Disposition_LOI map must be exactly Received -> Under Review -> Countered by '
            + 'DPEG -> Counter Received from Buyer -> Executed. The direction is REVERSED from the '
            + 'acquisition path (the LOI arrives from the buyer rather than being drafted by us), '
            + 'which is why there is no Draft, no Prepare/Review and no Sent');
        Assert.areEqual('Executed', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'The walk must leave the disposition LOI at its terminal stage');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 Contract_Review__c (Tranche 3C) — ONE MAP SHARED BY REFERENCE, TWO GATES
    //
    // Handed back from the 3C developer as a known, deliberate gap: this class had ZERO
    // Contract_Review__c coverage before this pass — not in a walk test, not in
    // adminPassesTheGateOnEveryObject, not in the per-record-type query-count test. The dispatch
    // that made this object's GATE record-type-aware (RT_ACQUISITION_PSA -> DEAL_DRIVER,
    // RT_DISPOSITION_PSA -> DISPOSITION_DRIVER, both StageTypeConfigs pointing at the SAME
    // CONTRACT_REVIEW_NEXT_STAGE map object) was therefore compile-verified only. Closed here.
    //
    // Unlike NDA__c and LOI__c, the two walks below are expected to be BYTE-IDENTICAL: both
    // record types share one sequence by reference, and differ ONLY in the gate. That is why the
    // gate test immediately below is "the falsifier for the whole 3C gate change" — the walks
    // cannot distinguish a correct build from one that reverted the gate split, since the sequence
    // never changed either way.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void acquisitionPsaWalksInitialDraftToExecuted() {
        Id crId = insertContractReviewOnRecordType(RT_ACQUISITION_PSA, 'Initial Draft').Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(crId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Contract Review moved to Revised.',
                'Contract Review moved to Ready for Execution.',
                'Contract Review moved to Executed.',
                'BLOCKED: There is no next step available from the Executed stage.'
            },
            messages,
            'The Acquisition_PSA map must be exactly Initial Draft -> Revised -> Ready for '
            + 'Execution -> Executed, with Executed terminal');
        Assert.areEqual('Executed',
            [SELECT Negotiation_Status__c FROM Contract_Review__c WHERE Id = :crId]
                .Negotiation_Status__c,
            'The walk must leave the Contract Review at its terminal status');
    }

    @isTest
    static void dispositionPsaWalksInitialDraftToExecuted() {
        // 🔴 THE CASE THAT PROVES THE GATE AND THE SEQUENCE ARE INDEPENDENT AXES. This walk must
        // be BYTE-IDENTICAL to acquisitionPsaWalksInitialDraftToExecuted above — both
        // StageTypeConfigs point at the SAME map object (CONTRACT_REVIEW_NEXT_STAGE) by reference,
        // not by copy. A divergent message list here would mean the map was duplicated rather than
        // shared, which is exactly the drift the class header says sharing-by-reference exists to
        // make unexpressible.
        Id crId = insertContractReviewOnRecordType(RT_DISPOSITION_PSA, 'Initial Draft').Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(crId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Contract Review moved to Revised.',
                'Contract Review moved to Ready for Execution.',
                'Contract Review moved to Executed.',
                'BLOCKED: There is no next step available from the Executed stage.'
            },
            messages,
            'The Disposition_PSA map must be BYTE-IDENTICAL to the Acquisition_PSA one — both '
            + 'point at CONTRACT_REVIEW_NEXT_STAGE by reference, not by copy');
        Assert.areEqual('Executed',
            [SELECT Negotiation_Status__c FROM Contract_Review__c WHERE Id = :crId]
                .Negotiation_Status__c,
            'The walk must leave the Contract Review at its terminal status');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 Transaction__c (added 2026-08-12, live UI testing fix set) — the FIRST object here
    // from the TRANSACTIONS module rather than acquisitions/disposition. ⚠ This comment used to
    // add "and the first whose gate is MEMBERSHIP-ONLY"; that held for part of one day, until the
    // custom-permission migration made all three gates one shape (see StageActionGate). Nothing
    // below depends on it — this section pins the SEQUENCE, never the gate.
    // It has NO record types (single-sequence StageConfig) and NO
    // explicit-target allow-list — the sequence is a straight line, so advanceTo() must be
    // STRUCTURALLY UNREACHABLE here. See class header + TransactionActionPermissionService for
    // the full argument; this section pins the sequence and the unreachability, not the gate
    // itself (the gate has its own class + test file, TransactionActionPermissionServiceTest).
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void transactionWalksOpenContractThroughToClosedWon() {
        // 🔴 THE ORDER IS A USER DECISION, CONFIRMED AT GATE 1 ON 2026-08-12 AGAINST THE ORG'S
        // LIVE PICKLIST — do not "correct" it from the Path's step text, which argues the other
        // way (see TRANSACTION_NEXT_STAGE's own header). This walk is where a reversion to the
        // step-text reading (…Closing Prep -> Closed Won -> Post-Closing) would surface.
        Id txnId = insertTransaction().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(txnId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Transaction moved to Due Diligence.',
                'Transaction moved to Closing Prep.',
                'Transaction moved to Post-Closing.',
                'Transaction moved to Closed Won.',
                'BLOCKED: There is no next step available from the Closed Won stage.'
            },
            messages,
            'The Transaction__c map must be exactly Open Contract -> Due Diligence -> Closing Prep '
            + '-> Post-Closing -> Closed Won, with Closed Won terminal. This object supplies no '
            + 'NO_NEXT_STEP_HINTS entry, so the generic terminal wording is expected, unlike '
            + 'Underwriting\'s approval-owned gap');
        Assert.areEqual('Closed Won', [SELECT Stage__c FROM Transaction__c WHERE Id = :txnId].Stage__c,
            'The walk must leave the Transaction at its terminal stage');
    }

    /**
     * 🔴 advanceTo() MUST BE STRUCTURALLY UNREACHABLE ON Transaction__c. The sequence is a straight
     * line — no branch, no off-ramp, no loop — so TRANSACTION_NEXT_STAGE's owning StageTypeConfig is
     * built through the two-argument (linear) constructor, which supplies an EMPTY explicitTargets
     * set. Every derivable forward hop belongs to advance(); listing any of them here would let a
     * direct Apex call skip Due Diligence and land a deal on 'Closed Won' in one call. Tries a value
     * that IS a real, valid stage on this object ('Post-Closing') specifically because that is the
     * sharper failure mode than a nonsense string — the refusal must be about the ALLOW-LIST being
     * empty, not about the target being unrecognised.
     */
    @isTest
    static void transactionAdvanceToIsStructurallyUnreachable() {
        Id txnId = insertTransaction().Id;

        Test.startTest();
        Boolean refused = false;
        try {
            RecordStageAdvanceService.advanceTo(txnId, 'Post-Closing');
            Assert.fail('advanceTo must refuse EVERY target on Transaction__c — its explicit-target '
                + 'allow-list is empty by construction');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            refused = true;
            Assert.areEqual('That stage is not available from this action.', e.getMessage(),
                'The allow-list refusal wording, not the unsupported-object or no-stage wording — '
                + 'proving the object WAS recognised and the record WAS loaded, and the empty '
                + 'allow-list is what refused the call');
        }
        Test.stopTest();

        Assert.isTrue(refused, 'advanceTo must refuse a Transaction with no configured explicit targets');
        Assert.areEqual('Open Contract', [SELECT Stage__c FROM Transaction__c WHERE Id = :txnId].Stage__c,
            'A refused advanceTo must not write — the stage stays exactly where it started');
    }

    @isTest
    static void constructionReviewWalksRequestedToCompleted() {
        Id reviewId = constructionReview().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(reviewId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Construction Feasibility Review moved to Site Visit.',
                'Construction Feasibility Review moved to Condition Assessment.',
                'Construction Feasibility Review moved to Cost Estimate.',
                'Construction Feasibility Review moved to Share Opinion.',
                'Construction Feasibility Review moved to Completed.',
                'BLOCKED: There is no next step available from the Completed stage.'
            },
            messages,
            'The Construction Feasibility Review map must be exactly Requested -> Site Visit -> '
            + 'Condition Assessment -> Cost Estimate -> Share Opinion -> Completed');
        Assert.areEqual('Completed',
            [SELECT Stage__c FROM Construction_Feasibility_Review__c WHERE Id = :reviewId].Stage__c,
            'The walk must leave the review at its terminal stage');
    }

    @isTest
    static void developmentReviewWalksRequestedToCompleted() {
        Id reviewId = developmentReview().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(reviewId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Development Feasibility Review moved to Feasibility analysis.',
                'Development Feasibility Review moved to Vendor proposals.',
                'Development Feasibility Review moved to Share Opinion.',
                'Development Feasibility Review moved to Completed.',
                'BLOCKED: There is no next step available from the Completed stage.'
            },
            messages,
            'The Development Feasibility Review map must be exactly Requested -> Feasibility '
            + 'analysis -> Vendor proposals -> Share Opinion -> Completed. The lower-cased second '
            + 'words are the org values — "correcting" them yields a map that never matches');
        Assert.areEqual('Completed',
            [SELECT Stage__c FROM Development_Feasibility_Review__c WHERE Id = :reviewId].Stage__c,
            'The walk must leave the review at its terminal stage');
    }

    @isTest
    static void underwritingWalksRequestedToInProgressThenStops() {
        Id underwritingId = underwriting().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(underwritingId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Underwriting moved to In Progress.',
                'BLOCKED: Underwriting moves to Approved through the principal approval, not this '
                + 'action. Use Submit for Approval.'
            },
            messages,
            'The Underwriting map must advance Requested -> In Progress and then STOP. Reaching '
            + 'Approved is the principal approval process\'s job');
    }

    @isTest
    static void underwritingResumesFromApprovedToCompleted() {
        // Simulates the state ApprovalAuditService leaves behind on principal sign-off. Proves the
        // Underwriting map is deliberately GAPPED rather than merely truncated — the Approved ->
        // Completed hop is live, so a reader cannot conclude the map "just stops at In Progress".
        Underwriting__c record = underwriting();
        record.Stage__c = 'Approved';
        update record;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(record.Id);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Underwriting moved to Completed.',
                'BLOCKED: There is no next step available from the Completed stage.'
            },
            messages,
            'From Approved the Underwriting map must still advance to Completed');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE APPROVAL CARVE-OUT
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void underwritingNeverReachesApprovedFromInProgress() {
        Underwriting__c record = underwriting();
        record.Stage__c = 'In Progress';
        update record;

        Test.startTest();
        Boolean refused = false;
        String message;
        try {
            RecordStageAdvanceService.advance(record.Id);
            Assert.fail('advance() must REFUSE In Progress -> Approved on Underwriting__c. '
                + 'Approved is owned by the principal approval process; a service that writes it '
                + 'directly lets a single button click produce a principal-approved underwriting '
                + 'that no principal ever saw');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            refused = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The In Progress -> Approved hop must be refused');
        Assert.areEqual('In Progress',
            [SELECT Stage__c FROM Underwriting__c WHERE Id = :record.Id].Stage__c,
            'A refused advance must not write. A stage of Approved here would mean the refusal '
            + 'happened AFTER the DML rather than instead of it');
        Assert.isTrue(message.contains('Submit for Approval'),
            'The refusal must NAME the real route, or the deliberate gap in the map reads as a bug '
            + 'and someone "fixes" it by adding the hop. Actual message: ' + message);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE PER-RECORD-TYPE EXPLICIT-TARGET ALLOW-LIST
    //
    // These two run in opposite directions on purpose. The refusal alone would pass in a build
    // where 'Declined' was simply never configured anywhere; the acceptance alone would pass in a
    // build where the allow-list was object-level and therefore leaked. Only the PAIR establishes
    // that the allow-list is scoped to the record type.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void acquisitionNdaRefusesTheDispositionOnlyDeclinedTarget() {
        // 🔴 THE FALSIFIER FOR THE SHARPEST DESIGN POINT IN TRANCHE 3A.
        //
        // Record-type picklist restrictions are enforced by the UI ONLY. Apex DML does not enforce
        // them, so `nda.Status__c = 'Declined'` on an Acquisition_NDA COMMITS — the platform will
        // not stop it. The only thing standing between class access and a disposition-only value on
        // an acquisition record is this allow-list being keyed by record type.
        //
        // The fixture sits on 'Sent' deliberately: that is the exact status the Mark Declined
        // action's visibility rule keys on, and it is SHARED by both record types. So this is not a
        // synthetic scenario — it is the state in which a real user is one hand-crafted call away
        // from the bug.
        NDA__c acquisitionNda = insertNdaOnRecordType(RT_ACQUISITION_NDA, 'Sent');

        Test.startTest();
        Boolean refused = false;
        String message;
        try {
            RecordStageAdvanceService.advanceTo(acquisitionNda.Id, 'Declined');
            Assert.fail('advanceTo MUST refuse a disposition-only stage on an acquisition NDA. '
                + 'Returning normally means the allow-list is keyed by OBJECT rather than by RECORD '
                + 'TYPE — a build that passes every stage-map walk and still writes Declined onto '
                + 'an acquisition record, because Apex DML does not enforce record-type picklist '
                + 'restrictions');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            refused = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The cross-record-type explicit target must be refused');
        Assert.areEqual('That stage is not available from this action.', message,
            'The refusal uses the shared allow-list wording and does NOT echo the supplied value '
            + 'back to the caller');
        Assert.areEqual('Sent',
            [SELECT Status__c FROM NDA__c WHERE Id = :acquisitionNda.Id].Status__c,
            'A refused advanceTo must not write. A status of Declined here would mean the refusal '
            + 'happened AFTER the DML rather than instead of it — note the allow-list check now '
            + 'runs after load(), so "checked before any write" is a property worth asserting '
            + 'rather than assuming');
    }

    @isTest
    static void dispositionNdaAcceptsDeclinedAsAnExplicitTarget() {
        // The complement. Without this, the refusal above could pass simply because 'Declined' was
        // configured for nobody — a broken feature masquerading as a secure one.
        NDA__c dispositionNda = insertNdaOnRecordType(RT_DISPOSITION_NDA, 'Sent');

        Test.startTest();
        String message = RecordStageAdvanceService.advanceTo(dispositionNda.Id, 'Declined');
        Test.stopTest();

        Assert.areEqual('NDA moved to Declined.', message,
            'Declined is the disposition NDA off-ramp and must be reachable by the Mark Declined '
            + 'action');
        Assert.areEqual('Declined',
            [SELECT Status__c FROM NDA__c WHERE Id = :dispositionNda.Id].Status__c,
            'and the write must actually land');
    }

    @isTest
    static void declinedIsNotReachableByAdvanceOnEitherRecordType() {
        // 'Declined' is an OFF-RAMP, not a hop. advance() derives its target from the sequence map,
        // and neither map contains an entry producing 'Declined' — so the only route to it is the
        // allow-listed explicit call above. This is the same discipline that keeps 'Approved' out of
        // the Underwriting map.
        Id acquisitionId = insertNdaOnRecordType(RT_ACQUISITION_NDA, 'Sent').Id;
        Id dispositionId = insertNdaOnRecordType(RT_DISPOSITION_NDA, 'Sent').Id;

        Test.startTest();
        String acquisitionMessage = RecordStageAdvanceService.advance(acquisitionId);
        String dispositionMessage = RecordStageAdvanceService.advance(dispositionId);
        Test.stopTest();

        Assert.isFalse(acquisitionMessage.contains('Declined'),
            'advance() must never derive Declined on an acquisition NDA; got: ' + acquisitionMessage);
        Assert.isFalse(dispositionMessage.contains('Declined'),
            'advance() must never derive Declined on a disposition NDA either — it is an off-ramp '
            + 'reached only by the named action; got: ' + dispositionMessage);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE SAME ALLOW-LIST HOLE ON LOI__c, TESTED IN BOTH DIRECTIONS (Tranche 3B)
    //
    // LOI__c inherited an OBJECT-level LOI_EXPLICIT_TARGETS = {Counter, Completed} from the
    // 2026-08-05 branch work. Tranche 3B splits it per record type. Both leaks are real and
    // neither is caught by any stage-map walk, because Apex DML does not enforce record-type
    // picklist restriction — a walk only proves what advance() DERIVES, never what advanceTo()
    // will WRITE.
    //
    // ⚠ The complement that stops the acquisition refusal passing vacuously already exists:
    // RecordStageAdvanceControllerTest.advanceToWritesAnAllowedExplicitTarget writes 'Completed'
    // on an acquisition LOI and asserts it lands. Do not delete it.
    //
    // 🔴 AT THE 3B CLOSE-OUT THE SECOND DIRECTION BECAME REAL. Until the negotiation-loop actions
    // landed, Disposition_LOI supplied NO explicit targets, so
    // acquisitionLoiRefusesADispositionStageAsAnExplicitTarget could only prove that the
    // acquisition list had not widened to the union of both value sets — it used 'Executed', a
    // stage no allow-list anywhere carries. It now aims the two REAL disposition-only targets at an
    // acquisition LOI, which is the leak the split exists to close, and
    // dispositionLoiAcceptsTheNegotiationLoopTargets is its complement.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void dispositionLoiRefusesTheAcquisitionExplicitTargets() {
        // DIRECTION 1: acquisition-only stages must not be writable onto a sale.
        // 'Completed' is on the ACQUISITION allow-list and is not a Disposition_LOI value at all.
        // Held at object level this call SUCCEEDS and silently parks a sale on a buy-side stage
        // that matches neither the disposition Path nor any flexipage rule keyed on it.
        LOI__c dispositionLoi = insertLoiOnRecordType(RT_DISPOSITION_LOI, 'Under Review');

        Test.startTest();
        Boolean refusedCompleted = false;
        Boolean refusedCounter = false;
        try {
            RecordStageAdvanceService.advanceTo(dispositionLoi.Id, 'Completed');
            Assert.fail('advanceTo MUST refuse the acquisition-only stage "Completed" on a '
                + 'disposition LOI. Returning normally means LOI__c\'s allow-list is still keyed '
                + 'by OBJECT rather than by RECORD TYPE.');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            refusedCompleted = true;
            Assert.areEqual('That stage is not available from this action.', e.getMessage(),
                'The refusal uses the shared allow-list wording and does not echo the value back');
        }
        try {
            RecordStageAdvanceService.advanceTo(dispositionLoi.Id, 'Counter');
            Assert.fail('advanceTo MUST refuse "Counter" too — BOTH acquisition explicit targets '
                + 'leak, not just the terminal one');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            refusedCounter = true;
        }
        Test.stopTest();

        Assert.isTrue(refusedCompleted && refusedCounter,
            'Both acquisition explicit targets must be refused on a disposition LOI');
        Assert.areEqual('Under Review',
            [SELECT Stage__c FROM LOI__c WHERE Id = :dispositionLoi.Id].Stage__c,
            'A refused advanceTo must not write. Note the allow-list check runs AFTER load(), so '
            + '"refused instead of written" is a property worth asserting rather than assuming');
    }

    @isTest
    static void acquisitionLoiRefusesADispositionStageAsAnExplicitTarget() {
        // DIRECTION 2: the mirror, and since the 3B close-out it is the SHARPER of the two.
        //
        // 'Executed' is the control: it is on NO allow-list anywhere, so refusing it only proves
        // the acquisition list has not widened to the union of both value sets.
        //
        // 🔴 The two that matter are 'Countered by DPEG' and 'Counter Received from Buyer'. Those
        // ARE allow-listed — on Disposition_LOI — and are the exact literals c/loiMarkCounteredBy-
        // Dpeg and c/loiMarkCounterReceived send. Held at OBJECT level, aiming either bundle's
        // payload at an acquisition LOI's Id would SUCCEED and park a purchase on a sell-side
        // stage, because Apex DML does not enforce record-type picklist restriction. This test is
        // the only thing in the system that refuses it — the picklist itself will not.
        LOI__c acquisitionLoi = insertLoiOnRecordType(RT_ACQUISITION_LOI, 'Sent');

        Test.startTest();
        Map<String, Boolean> refusedByTarget = new Map<String, Boolean>();
        for (String target : new List<String>{
            'Executed', 'Countered by DPEG', 'Counter Received from Buyer'
        }) {
            refusedByTarget.put(target, false);
            try {
                RecordStageAdvanceService.advanceTo(acquisitionLoi.Id, target);
                Assert.fail('advanceTo MUST refuse the disposition-only stage "' + target
                    + '" on an acquisition LOI. Returning normally means LOI__c\'s allow-list has '
                    + 'been moved back to OBJECT level, or the disposition loop targets were added '
                    + 'to LOI_ACQUISITION_EXPLICIT_TARGETS.');
            } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
                refusedByTarget.put(target, true);
                Assert.areEqual('That stage is not available from this action.', e.getMessage(),
                    'The refusal uses the shared allow-list wording and does not echo the value '
                    + 'back (target: ' + target + ')');
            }
        }
        Test.stopTest();

        Assert.areEqual(new Map<String, Boolean>{
            'Executed' => true,
            'Countered by DPEG' => true,
            'Counter Received from Buyer' => true
        }, refusedByTarget,
            'Every disposition-only stage must be refused on an acquisition LOI — the two loop '
            + 'targets especially, since those are the ones a real deployed bundle can send');
        Assert.areEqual('Sent',
            [SELECT Stage__c FROM LOI__c WHERE Id = :acquisitionLoi.Id].Stage__c,
            'A refused advanceTo must not write. Note the allow-list check runs AFTER load(), so '
            + '"refused instead of written" is a property worth asserting rather than assuming');
    }

    @isTest
    static void dispositionLoiAcceptsTheNegotiationLoopTargets() {
        // THE COMPLEMENT to the refusal above. Without it, that test could pass simply because
        // these two values were configured NOWHERE at all — a build that deleted
        // LOI_DISPOSITION_EXPLICIT_TARGETS entirely would look identical from there.
        //
        // 🔴 THE FIRST HALF IS THE BACK-EDGE, AND IT IS THE WHOLE REASON THIS SET EXISTS.
        // 'Counter Received from Buyer' -> 'Countered by DPEG' is the one transition
        // LOI_DISPOSITION_NEXT_STAGE provably CANNOT express: that key already maps forward to
        // 'Executed', and a Map<String, String> holds one value per key. So advance() can never
        // reach it, at any price — which the second assertion pins by walking advance() from the
        // same stage and watching it go the OTHER way.
        LOI__c loi = insertLoiOnRecordType(RT_DISPOSITION_LOI, 'Counter Received from Buyer');

        Test.startTest();
        String backEdge = RecordStageAdvanceService.advanceTo(loi.Id, 'Countered by DPEG');
        // ...and round again: the forward edge, which OVERLAPS advance() deliberately. Doing both
        // in sequence is what proves the cycle is traversable more than once, i.e. that the
        // negotiation can genuinely "go round until both sides are agreed" (Part 2 line 244).
        String forwardEdge =
            RecordStageAdvanceService.advanceTo(loi.Id, 'Counter Received from Buyer');
        String derived = RecordStageAdvanceService.advance(loi.Id);
        Test.stopTest();

        Assert.areEqual('LOI moved to Countered by DPEG.', backEdge,
            'The loop BACK-EDGE must be reachable through advanceTo — it is unreachable by any '
            + 'other route in the system');
        Assert.areEqual('LOI moved to Counter Received from Buyer.', forwardEdge,
            'The loop FORWARD edge is allow-listed too, deliberately, even though advance() can '
            + 'also derive it — see LOI_DISPOSITION_EXPLICIT_TARGETS for the symmetry and '
            + 'independence reasons. Removing it would silently drop the named button');
        Assert.areEqual('LOI moved to Executed.', derived,
            'advance() must still derive Executed from Counter Received from Buyer. If the loop '
            + 'had been built by editing LOI_DISPOSITION_NEXT_STAGE instead of adding explicit '
            + 'targets, this hop would have been overwritten and the sell-side path could never '
            + 'terminate');
        Assert.areEqual('Executed',
            [SELECT Stage__c FROM LOI__c WHERE Id = :loi.Id].Stage__c,
            'and the final write must actually land');
    }

    @isTest
    static void loiGateIsResolvedPerRecordTypeNotPerObject() {
        // The LOI twin of theGateIsResolvedPerRecordTypeNotPerObject. Acquisition_LOI answers to
        // DEAL_DRIVER and Disposition_LOI to DISPOSITION_DRIVER — held at object level, an
        // acquisitions deal driver could drive a SALE's LOI, and a disposition driver could drive
        // an acquisition's. Both caches are pre-seeded with OPPOSITE answers and BOTH polarities
        // are asserted, so a hardcoded constant cannot pass. (The honest alternative — two real
        // personas under System.runAs — cannot work on an OWD-Private object whose selector would
        // throw before the gate was ever consulted.)
        Id acquisitionLoiId = insertLoiOnRecordType(RT_ACQUISITION_LOI, 'Draft').Id;
        Id dispositionLoiId = insertLoiOnRecordType(RT_DISPOSITION_LOI, 'Received').Id;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        OpportunityActionPermissionService.cachedHasDealActionAccess = true;
        DispositionActionPermissionService.cachedHasDispositionActionAccess = false;

        Boolean acquisitionWhenDealDriverOnly =
            RecordStageAdvanceService.hasStageActionAccess(acquisitionLoiId);
        Boolean dispositionWhenDealDriverOnly =
            RecordStageAdvanceService.hasStageActionAccess(dispositionLoiId);

        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        OpportunityActionPermissionService.cachedHasDealActionAccess = false;
        DispositionActionPermissionService.cachedHasDispositionActionAccess = true;

        Boolean acquisitionWhenDispositionDriverOnly =
            RecordStageAdvanceService.hasStageActionAccess(acquisitionLoiId);
        Boolean dispositionWhenDispositionDriverOnly =
            RecordStageAdvanceService.hasStageActionAccess(dispositionLoiId);

        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(acquisitionWhenDealDriverOnly,
            'An Acquisition_LOI must answer to the ACQUISITIONS gate');
        Assert.isFalse(dispositionWhenDealDriverOnly,
            'A Disposition_LOI must NOT be driveable by an acquisitions deal driver. True here '
            + 'means the gate is keyed by object and the sale inherited the buy-side persona.');
        Assert.isTrue(dispositionWhenDispositionDriverOnly,
            'A Disposition_LOI must answer to the DISPOSITION gate');
        Assert.isFalse(acquisitionWhenDispositionDriverOnly,
            'An Acquisition_LOI must NOT be driveable by a disposition driver either — the leak '
            + 'runs in both directions and only asserting one of them proves nothing');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // GUARD CLAUSES
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void nullRecordIdThrows() {
        Test.startTest();
        try {
            RecordStageAdvanceService.advance(null);
            Assert.fail('A null recordId must be rejected');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('No record was provided.', e.getMessage(),
                'A null recordId surfaces the fixed no-record wording');
        }
        Test.stopTest();
    }

    @isTest
    static void unsupportedObjectThrows() {
        // An Opportunity is stage-controlled by the OTHER service (StageAdvanceService). Handing it
        // to this one must be refused rather than silently mis-routed.
        Id oppId = dealId();

        Test.startTest();
        try {
            RecordStageAdvanceService.advance(oppId);
            Assert.fail('An Opportunity is not stage-controlled by this service');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('This action is not available on this record.', e.getMessage(),
                'An unsupported object surfaces the fixed unsupported wording');
        }
        Test.stopTest();
    }

    @isTest
    static void blankStageThrows() {
        // Blanked by UPDATE, not by insert: a picklist default is applied on insert when the field
        // is omitted, so an insert cannot reach this state.
        LOI__c record = loi();
        record.Stage__c = null;
        update record;

        Test.startTest();
        try {
            RecordStageAdvanceService.advance(record.Id);
            Assert.fail('A record with no stage cannot be advanced');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('This record has no stage set, so it cannot be advanced.', e.getMessage(),
                'A blank stage surfaces its own wording rather than "no next step available from '
                + 'the  stage"');
        }
        Test.stopTest();
    }

    @isTest
    static void missingRecordThrowsQueryException() {
        // The selectors are FETCH-FOR-USE: a miss throws the native System.QueryException, which
        // this service deliberately does NOT convert. The controller masks it behind a fixed
        // generic message; converting it here would make a genuine fault read as a business rule.
        LOI__c record = loi();
        Id deletedId = record.Id;
        delete record;

        Test.startTest();
        try {
            RecordStageAdvanceService.advance(deletedId);
            Assert.fail('A deleted record must not be advanced');
        } catch (System.QueryException e) {
            Assert.isNotNull(e, 'A missing record surfaces the native QueryException');
        }
        Test.stopTest();
    }

    @isTest
    static void advanceToOnAMissingRecordThrowsQueryExceptionNotARefusal() {
        // ⚠ PINS THE ONE VISIBLE CONSEQUENCE OF THE CALL-ORDER CHANGE (2026-08-09).
        // advanceTo used to check the allow-list BEFORE loading, so a disallowed target on a
        // non-existent Id was refused with RecordStageAdvanceException. The allow-list is now a
        // property of the record type, which is a property of the row, so the load has to happen
        // first and a missing row now raises the native QueryException instead. Both are masked
        // behind fixed generic messages at the controller, so nothing a user sees changes — but the
        // ordering is deliberate and a future "optimisation" that moves the check back in front of
        // the load would silently restore the object-level allow-list. This test is what stops that.
        LOI__c record = loi();
        Id deletedId = record.Id;
        delete record;

        Test.startTest();
        try {
            RecordStageAdvanceService.advanceTo(deletedId, 'Signed');
            Assert.fail('A deleted record must not be advanced');
        } catch (System.QueryException e) {
            Assert.isNotNull(e, 'The load runs before the allow-list check, so the miss surfaces '
                + 'the native QueryException');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.fail('The allow-list must be consulted AFTER the record is loaded, because it '
                + 'is keyed by record type. A RecordStageAdvanceException here means the check ran '
                + 'first and is therefore object-level. Message: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void advanceToStillRejectsABlankTargetBeforeAnythingElse() {
        // The blank-target guard is the ONE check that deliberately stays AHEAD of the load: it
        // needs no record to answer. Whitespace-only is used rather than '' because
        // String.isBlank — not isEmpty — is what the service calls, and only this input tells the
        // two apart.
        Id loiId = loi().Id;
        Boolean refused = false;

        Test.startTest();
        try {
            RecordStageAdvanceService.advanceTo(loiId, '   ');
            Assert.fail('A whitespace-only target must be refused');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            refused = true;
            Assert.areEqual('No target stage was provided.', e.getMessage(),
                'The blank-target wording is fixed and reaches the caller verbatim');
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A whitespace-only target is blank and must be refused');
        Assert.areEqual('Draft', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'and nothing may be written');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PERMISSION GATE
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void adminPassesTheGateOnEveryObject() {
        // The test-running user holds Modify All Data, which the gate bypasses on purpose (see
        // OpportunityActionPermissionService). ⚠ This is exactly why an admin smoke test proves
        // nothing about the gate — the denial case below is the one that does.
        Id ndaId = nda().Id;
        Id loiId = loi().Id;
        Id underwritingId = underwriting().Id;
        Id conId = constructionReview().Id;
        Id devId = developmentReview().Id;
        Id crId = contractReview().Id;
        // ⚠ REWRITTEN 2026-08-12 (custom-permission migration): Transaction__c answers to
        // TRANSACTION_STAGE_ACTIONS via TransactionActionPermissionService, which now owns its OWN
        // transaction-scoped cache — it no longer delegates to LeadActionPermissionService at all —
        // so its bypass is cleared through TransactionActionPermissionService.clearCache(), a
        // DIFFERENT cache from the other six objects' OpportunityActionPermissionService /
        // DispositionActionPermissionService bypass.
        Id txnId = insertTransaction().Id;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        TransactionActionPermissionService.clearCache();
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(ndaId), 'NDA gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(loiId), 'LOI gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(underwritingId), 'Underwriting gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(conId), 'Construction gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(devId), 'Development gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(crId), 'Contract Review gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(txnId),
            'Transaction gate — the admin passes via the Modify All Data bypass INSIDE '
            + 'TransactionActionPermissionService itself, a different code path (and a different '
            + 'cache) from the other six objects\' OpportunityActionPermissionService / '
            + 'DispositionActionPermissionService bypass');
        RecordStageAdvanceService.assertStageActionAccess(loiId); // must not throw
        RecordStageAdvanceService.assertStageActionAccess(txnId); // must not throw
        OpportunityActionPermissionService.clearCache();
        TransactionActionPermissionService.clearCache();
        Test.stopTest();
    }

    /**
     * ⚠ THE SUBJECT MOVED FROM LOI__c TO Underwriting__c IN TRANCHE 3B, AND THE REASON IS A REAL
     * BEHAVIOURAL CONSEQUENCE, NOT TEST TIDYING.
     *
     * This is the ONLY test in the class that denies through a REAL persona rather than a seeded
     * cache, so it has to run on an object whose gate is knowable from the Id ALONE. The moment
     * LOI__c gained two record types, gateFor() started LOADING the row to decide which gate
     * applies — and LOI__c is OWD Private, so a bare Standard User's `WITH USER_MODE` selector read
     * returns no row and raises System.QueryException BEFORE any gate is consulted. The test would
     * then have "passed" on a read failure while proving nothing about the gate.
     *
     * ⇒ CONSEQUENCE WORTH KNOWING, DELIBERATELY UNCHANGED FROM ITS 3A SHAPE: on a MULTI-record-type
     *   object a caller who cannot READ the record now gets the controller's generic
     *   "could not be updated" message rather than the denial wording. It still fails CLOSED, and
     *   it is unreachable from the UI (the quick action lives on the record page, so a user who
     *   reaches it can already read the record) — it is reachable only by a direct @AuraEnabled
     *   call from someone with class access but no object access. NDA__c has had exactly this shape
     *   since 3A; 3B extends it to LOI__c. Making the gate answer instead of throw was rejected in
     *   3A on the stated ground that a fault must not read as a denial.
     *
     * Underwriting__c is equally OWD Private and equally DEAL_DRIVER-gated; it simply has ONE
     * configured sequence, so gateFor() short-circuits and no read happens.
     */
    @isTest
    static void bareUserIsDeniedAndNothingIsWritten() {
        Id underwritingId = underwriting().Id;
        User bareUser = buildStandardUser('bare');
        insert bareUser;   // setup DML first — no record DML has run in this transaction yet

        Test.startTest();
        Boolean refused = false;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            Assert.isFalse(RecordStageAdvanceService.hasStageActionAccess(underwritingId),
                'A user with neither Modify All Data nor the Acquisition_Deal_Actions custom '
                + 'permission must be denied');
            try {
                RecordStageAdvanceService.assertStageActionAccess(underwritingId);
                Assert.fail('assertStageActionAccess must REFUSE a non-deal-driver. Returning '
                    + 'normally means the gate did not run at all');
            } catch (RecordStageAdvanceService.AccessDeniedException e) {
                refused = true;
                Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE,
                    e.getMessage(),
                    'The denial must use the SHARED wording, so one condition never produces two '
                    + 'phrasings across the Lead, Opportunity and record-stage features');
            }
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The server-side assert must refuse a non-deal-driver');
        Assert.areEqual('Requested',
            [SELECT Stage__c FROM Underwriting__c WHERE Id = :underwritingId].Stage__c,
            'A refused call must not write');
    }

    /**
     * 🔴 THE GATE IS RESOLVED PER RECORD TYPE — the falsifier for the D15/Q1 wiring.
     *
     * The two NDA record types answer to DIFFERENT personas: Acquisition_NDA to DEAL_DRIVER and
     * Disposition_NDA to DISPOSITION_DRIVER. Held at OBJECT level (where the gate lived until
     * 2026-08-09) both would answer to whichever single gate was configured, and an acquisitions
     * deal driver could drive a SALE's NDA.
     *
     * ⚠ THE TWO SERVICE CACHES ARE PRE-SEEDED WITH OPPOSITE ANSWERS, AND THAT IS THE TECHNIQUE,
     * NOT A SHORTCUT. The honest alternative — provisioning two real personas with System.runAs —
     * cannot work here: NDA__c is OWD Private and a bare Standard User has no object access at
     * all, so `WITH USER_MODE` inside the selector would throw before the gate was ever consulted,
     * and the test would pass for entirely the wrong reason. Seeding the caches makes the two
     * gates TELLABLE APART with one bit each, which is precisely what "is the dispatch correct?"
     * needs. Whether each gate itself is correct is DispositionActionPermissionServiceTest's and
     * OpportunityActionPermissionServiceTest's job, under real runAs.
     */
    @isTest
    static void theGateIsResolvedPerRecordTypeNotPerObject() {
        Id acquisitionId = insertNdaOnRecordType(RT_ACQUISITION_NDA, 'Sent').Id;
        Id dispositionId = insertNdaOnRecordType(RT_DISPOSITION_NDA, 'Sent').Id;

        Test.startTest();
        // Polarity 1: acquisitions DENIED, disposition ALLOWED.
        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        OpportunityActionPermissionService.cachedHasDealActionAccess = false;
        DispositionActionPermissionService.cachedHasDispositionActionAccess = true;
        Boolean acquisitionUnderPolarity1 =
            RecordStageAdvanceService.hasStageActionAccess(acquisitionId);
        Boolean dispositionUnderPolarity1 =
            RecordStageAdvanceService.hasStageActionAccess(dispositionId);

        // Polarity 2: reversed. Running BOTH is what rules out a constant answer.
        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        OpportunityActionPermissionService.cachedHasDealActionAccess = true;
        DispositionActionPermissionService.cachedHasDispositionActionAccess = false;
        Boolean acquisitionUnderPolarity2 =
            RecordStageAdvanceService.hasStageActionAccess(acquisitionId);
        Boolean dispositionUnderPolarity2 =
            RecordStageAdvanceService.hasStageActionAccess(dispositionId);

        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(acquisitionUnderPolarity1,
            'An ACQUISITION NDA must answer to the DEAL_DRIVER gate, which is denying here');
        Assert.isTrue(dispositionUnderPolarity1,
            'A DISPOSITION NDA must answer to the DISPOSITION_DRIVER gate, which is granting here. '
            + 'If this is false the gate is still object-level and every disposition NDA is gated '
            + 'behind the ACQUISITIONS persona.');
        Assert.isTrue(acquisitionUnderPolarity2,
            'Reversed: the acquisition NDA now follows the deal-driver gate to true');
        Assert.isFalse(dispositionUnderPolarity2,
            'Reversed: the disposition NDA now follows the disposition-driver gate to false. Both '
            + 'polarities are asserted so a hardcoded constant cannot pass this test.');
    }

    /**
     * 🔴 THE FALSIFIER FOR THE WHOLE TRANCHE 3C GATE CHANGE — closes the gap the 3C developer
     * handed back: this dispatch was compile-verified only.
     *
     * The two Contract_Review__c record types answer to DIFFERENT personas: Acquisition_PSA to
     * DEAL_DRIVER and Disposition_PSA to DISPOSITION_DRIVER — despite sharing ONE
     * CONTRACT_REVIEW_NEXT_STAGE map object by reference. Left on the old single-sequence
     * DEAL_DRIVER config, hasStageActionAccess / assertStageActionAccess would refuse EVERY
     * disposition PSA for the only persona meant to work it — a dead feature passing every walk
     * test above, since the sequence is identical either way. Only this test can tell the two
     * builds apart.
     *
     * Same technique as theGateIsResolvedPerRecordTypeNotPerObject (NDA) and
     * loiGateIsResolvedPerRecordTypeNotPerObject (LOI): both permission caches are pre-seeded with
     * OPPOSITE answers and BOTH polarities are asserted, because the honest alternative — two real
     * personas under System.runAs — cannot work here. Contract_Review__c is OWD Private and a bare
     * Standard User's `WITH USER_MODE` selector read would throw before any gate was consulted.
     */
    @isTest
    static void contractReviewGateIsResolvedPerRecordTypeNotPerObject() {
        Id acquisitionId = insertContractReviewOnRecordType(RT_ACQUISITION_PSA, 'Initial Draft').Id;
        Id dispositionId = insertContractReviewOnRecordType(RT_DISPOSITION_PSA, 'Initial Draft').Id;

        Test.startTest();
        // Polarity 1: acquisitions DENIED, disposition ALLOWED.
        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        OpportunityActionPermissionService.cachedHasDealActionAccess = false;
        DispositionActionPermissionService.cachedHasDispositionActionAccess = true;
        Boolean acquisitionUnderPolarity1 =
            RecordStageAdvanceService.hasStageActionAccess(acquisitionId);
        Boolean dispositionUnderPolarity1 =
            RecordStageAdvanceService.hasStageActionAccess(dispositionId);

        // Polarity 2: reversed. Running BOTH is what rules out a constant answer.
        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        OpportunityActionPermissionService.cachedHasDealActionAccess = true;
        DispositionActionPermissionService.cachedHasDispositionActionAccess = false;
        Boolean acquisitionUnderPolarity2 =
            RecordStageAdvanceService.hasStageActionAccess(acquisitionId);
        Boolean dispositionUnderPolarity2 =
            RecordStageAdvanceService.hasStageActionAccess(dispositionId);

        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(acquisitionUnderPolarity1,
            'An ACQUISITION_PSA must answer to the DEAL_DRIVER gate, which is denying here. True '
            + 'here means the config reverted to a single shared gate and every acquisition PSA is '
            + 'now gated behind the DISPOSITION persona.');
        Assert.isTrue(dispositionUnderPolarity1,
            'A DISPOSITION_PSA must answer to the DISPOSITION_DRIVER gate, which is granting here. '
            + 'False here is the EXACT dead-feature scenario the 3C developer flagged: a '
            + 'disposition driver refused on the only PSA record type they own, with every walk '
            + 'test above still green because the sequence never changed.');
        Assert.isTrue(acquisitionUnderPolarity2,
            'Reversed: the acquisition PSA now follows the deal-driver gate to true');
        Assert.isFalse(dispositionUnderPolarity2,
            'Reversed: the disposition PSA now follows the disposition-driver gate to false. Both '
            + 'polarities are asserted so a hardcoded constant cannot pass this test.');
    }

    /**
     * The assert path for the disposition gate: a refusal must carry the SHARED denial wording, so
     * a user never sees two phrasings for one condition — and, deliberately, cannot tell WHICH of
     * the two gates refused. "Which permission you are missing" is not information a refused
     * caller is owed.
     */
    @isTest
    static void assertRefusesADispositionNdaWhenTheDispositionGateDenies() {
        Id dispositionId = insertNdaOnRecordType(RT_DISPOSITION_NDA, 'Sent').Id;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        // Acquisitions ALLOWED, disposition DENIED: if the dispatch were wrong this would pass.
        OpportunityActionPermissionService.cachedHasDealActionAccess = true;
        DispositionActionPermissionService.cachedHasDispositionActionAccess = false;

        Boolean refused = false;
        try {
            RecordStageAdvanceService.assertStageActionAccess(dispositionId);
            Assert.fail('assertStageActionAccess must REFUSE when the DISPOSITION gate denies, '
                + 'even though the acquisitions gate is granting');
        } catch (RecordStageAdvanceService.AccessDeniedException e) {
            refused = true;
            Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE,
                e.getMessage(),
                'One wording for every gate and every feature');
        }
        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The disposition gate must be able to refuse');
    }

    /**
     * 🔴 THE TRANSACTION GATE END TO END, THROUGH REAL System.runAs PERSONAS — not a seeded cache.
     *
     * Unlike the two `*_DRIVER` gates, TRANSACTION_STAGE_ACTIONS never loads the record to decide
     * which gate applies (Transaction__c has a single sequence — see
     * gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject), so a bare user reaching
     * hasStageActionAccess never touches Transaction__c's OWD/CRUD at all and the honest,
     * cache-seeding-free proof used for the two-factor gates is unnecessary here. This test
     * therefore does what theirs structurally cannot: prove the WHOLE chain
     * (RecordStageAdvanceService -> TransactionActionPermissionService -> FeatureManagement) with a
     * real permission-set assignment under a real persona.
     *
     * ⚠ REWRITTEN 2026-08-12 (custom-permission migration): TransactionActionPermissionService no
     * longer delegates to LeadActionPermissionService — it owns its own cache — so every clearCache()
     * call below targets TransactionActionPermissionService directly, not the Lead gate's cache.
     */
    @isTest
    static void transactionGateDeniesABareUserAndGrantsAPermissionSetHolder() {
        Id txnId = insertTransaction().Id;
        User bareUser = buildStandardUser('rsaBare');
        User grantedUser = buildStandardUser('rsaGranted');
        Id transactionPermSetId = [
            SELECT Id FROM PermissionSet WHERE Name = 'Transaction_Stage_Actions_Access' LIMIT 1
        ].Id;
        // 🔴 MIXED_DML_OPERATION FIX (2026-08-12): insertTransaction() above is DML on a non-setup
        // object (Transaction__c), so the User + PermissionSetAssignment inserts below — both
        // setup-object DML — must be isolated in their own System.runAs block or the platform
        // throws "DML operation on setup object is not permitted after you have updated a
        // non-setup object". This is the SAME isolation technique already used in this repo for
        // this exact shape — see RecordStageAdvanceControllerTest
        // .refusesAUserWhoIsNotADealDriverAndWritesNothing and TaskRollupServiceTest's
        // buildMinimumAccessUser/assignPermissionSets callers. Do not "fix" this by reordering the
        // inserts ahead of insertTransaction() instead of wrapping them — a future test added above
        // this one that also performs non-setup DML in @TestSetup-adjacent code would silently
        // reintroduce the failure; the runAs isolation is robust regardless of ordering.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ bareUser, grantedUser };
            insert new PermissionSetAssignment(
                AssigneeId = grantedUser.Id, PermissionSetId = transactionPermSetId);
        }

        Test.startTest();
        Boolean bareAllowed;
        Boolean grantedAllowed;
        Boolean bareRefused = false;
        String bareRefusalMessage;
        TransactionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            bareAllowed = RecordStageAdvanceService.hasStageActionAccess(txnId);
            try {
                RecordStageAdvanceService.assertStageActionAccess(txnId);
                Assert.fail('assertStageActionAccess must REFUSE a user holding neither the '
                    + 'Transaction permission set nor Modify All Data');
            } catch (RecordStageAdvanceService.AccessDeniedException e) {
                bareRefused = true;
                bareRefusalMessage = e.getMessage();
            }
        }
        TransactionActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            grantedAllowed = RecordStageAdvanceService.hasStageActionAccess(txnId);
            RecordStageAdvanceService.assertStageActionAccess(txnId); // must not throw
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(bareAllowed, 'A user with neither the permission set nor Modify All Data must be denied');
        Assert.isTrue(bareRefused, 'The server-side assert must refuse the bare user');
        Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE, bareRefusalMessage,
            'The denial must use the SAME shared wording every other gate uses, so a user can never '
            + 'tell which of the four gates (Lead / Opportunity / Disposition / Transaction) refused '
            + 'them from the toast alone');
        Assert.isTrue(grantedAllowed,
            'A user holding Transaction_Stage_Actions_Access DIRECTLY must be allowed — proving the '
            + 'full RecordStageAdvanceService -> TransactionActionPermissionService -> '
            + 'FeatureManagement chain, not just the leaf service in isolation');
        Assert.areEqual('Open Contract', [SELECT Stage__c FROM Transaction__c WHERE Id = :txnId].Stage__c,
            'Neither hasStageActionAccess nor assertStageActionAccess ever writes — the stage is '
            + 'exactly where it started for both personas');
    }

    /**
     * The `size() == 1` short-circuit in gateFor(), asserted as a COST rather than by inspection.
     *
     * An object with one configured sequence has one gate by construction, so loading the row
     * could not change the answer — and hasStageActionAccess sits behind a `cacheable=true`
     * controller method invoked once per record VIEW, so paying a query on the four objects that
     * will never need it would be a real cost for no information.
     *
     * Both permission caches are pre-seeded so the gate itself issues no queries and the only
     * thing being measured is the record load.
     *
     * ⚠ REWRITTEN 2026-08-12 (custom-permission migration): TransactionActionPermissionService now
     * owns its own cache (cachedHasTransactionActionAccess) instead of delegating to
     * LeadActionPermissionService's cachedPermissionSetNames / cachedHasModifyAllData, so the
     * Transaction leg is pre-seeded directly rather than through the Lead gate's cache.
     */
    @isTest
    static void gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject() {
        // ⚠ CHANGED IN TRANCHE 3B, AND THE 3A VERSION OF THIS TEST PREDICTED IT IN WRITING: LOI__c
        // moved from 0 expected queries to 1 because it gained two record types with two different
        // gates. The single-sequence probe therefore moved to Underwriting__c, which keeps the
        // short-circuit honest — without a zero-query case, a regression that loaded the row for
        // EVERY object would pass unnoticed and quietly add a query to four record pages.
        Id underwritingId = underwriting().Id;
        Id loiId = insertLoiOnRecordType(RT_ACQUISITION_LOI, 'Draft').Id;
        Id ndaId = insertNdaOnRecordType(RT_ACQUISITION_NDA, 'Sent').Id;
        Id crId = insertContractReviewOnRecordType(RT_ACQUISITION_PSA, 'Initial Draft').Id;
        // ⚠ Transaction__c is the FIFTH single-sequence object and the only one whose gate runs
        // through its OWN cache (TransactionActionPermissionService's), so it is pre-seeded
        // separately below.
        Id txnId = insertTransaction().Id;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        TransactionActionPermissionService.clearCache();
        OpportunityActionPermissionService.cachedHasDealActionAccess = true;
        DispositionActionPermissionService.cachedHasDispositionActionAccess = true;
        // Pre-seed WITHOUT querying, isolating what this test actually measures: whether the RECORD
        // gets loaded, not whether the permission gate itself issues a query.
        TransactionActionPermissionService.cachedHasTransactionActionAccess = true;

        Integer beforeUnderwriting = Limits.getQueries();
        RecordStageAdvanceService.hasStageActionAccess(underwritingId);
        Integer underwritingQueries = Limits.getQueries() - beforeUnderwriting;

        Integer beforeLoi = Limits.getQueries();
        RecordStageAdvanceService.hasStageActionAccess(loiId);
        Integer loiQueries = Limits.getQueries() - beforeLoi;

        Integer beforeNda = Limits.getQueries();
        RecordStageAdvanceService.hasStageActionAccess(ndaId);
        Integer ndaQueries = Limits.getQueries() - beforeNda;

        Integer beforeCr = Limits.getQueries();
        RecordStageAdvanceService.hasStageActionAccess(crId);
        Integer crQueries = Limits.getQueries() - beforeCr;

        Integer beforeTxn = Limits.getQueries();
        RecordStageAdvanceService.hasStageActionAccess(txnId);
        Integer txnQueries = Limits.getQueries() - beforeTxn;

        OpportunityActionPermissionService.clearCache();
        DispositionActionPermissionService.clearCache();
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.areEqual(0, underwritingQueries,
            'Underwriting__c has ONE configured sequence, so its gate is knowable from the Id '
            + 'alone and the record must NOT be loaded. A 1 here means the short-circuit in '
            + 'gateFor() was lost and all four single-sequence objects now pay a query on every '
            + 'record view.');
        Assert.areEqual(0, txnQueries,
            'Transaction__c has NO record types at all (not merely one configured sequence like '
            + 'the other four) so gateFor() must short-circuit here too. A 1 here means the '
            + 'single-sequence optimisation regressed for the newest object.');
        Assert.areEqual(1, loiQueries,
            'LOI__c has TWO record types with DIFFERENT gates since Tranche 3B, so the row must '
            + 'be loaded to know which gate applies. Zero here would mean the gate fell back to '
            + 'the object default and every disposition LOI is gated behind the acquisitions '
            + 'persona.');
        Assert.areEqual(1, ndaQueries,
            'NDA__c has TWO record types with DIFFERENT gates, so the row must be loaded to know '
            + 'which gate applies. Zero here would mean the gate silently fell back to the object '
            + 'default and every disposition NDA is gated behind the acquisitions persona.');
        Assert.areEqual(1, crQueries,
            'Contract_Review__c has TWO record types with DIFFERENT gates since Tranche 3C — even '
            + 'though they share ONE sequence — so the row must be loaded to know which gate '
            + 'applies. Zero here would mean the gate silently fell back to the object default and '
            + 'every disposition PSA is gated behind the acquisitions persona.');
    }

    @isTest
    static void permissionCheckOnAnUnsupportedObjectThrows() {
        Id oppId = dealId();

        Test.startTest();
        try {
            RecordStageAdvanceService.hasStageActionAccess(oppId);
            Assert.fail('The gate cannot be resolved for an object with no stage config');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('This action is not available on this record.', e.getMessage(),
                'An unsupported object is refused before any permission machinery runs');
        }
        try {
            RecordStageAdvanceService.hasStageActionAccess(null);
            Assert.fail('A null recordId cannot resolve a gate');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('No record was provided.', e.getMessage(),
                'A null recordId surfaces the fixed no-record wording');
        }
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // isSupported
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void isSupportedAnswersWithoutThrowing() {
        Id loiId = loi().Id;
        Id oppId = dealId();

        Test.startTest();
        Assert.isTrue(RecordStageAdvanceService.isSupported(loiId),
            'LOI__c is stage-controlled by this service');
        Assert.isFalse(RecordStageAdvanceService.isSupported(oppId),
            'Opportunity belongs to StageAdvanceService, not this one');
        Assert.isFalse(RecordStageAdvanceService.isSupported(null),
            'isSupported is null-safe — it ANSWERS rather than throwing, which is the point of it '
            + 'existing alongside the throwing entry points');
        Test.stopTest();
    }

    /**
     * Builds (but does not insert) a bare Standard User. User is a setup object whose required-field
     * shape TestDataFactory deliberately does not cover, so this mirrors the helper in
     * StageAdvanceControllerTest / OpportunityActionPermissionServiceTest.
     */
    private static User buildStandardUser(String tag) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'RecStage',
            Alias = 'rstg',
            Email = 'std.recstage@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
