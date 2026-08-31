/**
 * Centralised test-data factory for the DPEG org.
 *
 * Mandated by ARCHITECTURE.md §2 ("Test data: always use TestDataFactory") and
 * listed there under Reference Implementations. Covers all 33 custom objects plus
 * the standard Account / Contact / Lead / Opportunity / Task surface the app uses.
 *
 * ╔═══════════════════════════════════════════════════════════════════════════╗
 * ║ ⚠ READ BEFORE USE — TWO THINGS THAT WILL BITE YOU                          ║
 * ╚═══════════════════════════════════════════════════════════════════════════╝
 *
 * ⚠ 1. THE SCAFFOLD CACHE DOES NOT CROSS THE @TestSetup BOUNDARY.
 *
 *   The default*() accessors (defaultProperty, defaultPropertyAsset, defaultUnit,
 *   defaultOpportunity, defaultTransaction, defaultDisposition, defaultLeaseInquiry,
 *   defaultLeaseRenewal, defaultWorkOrder, defaultContractReview, defaultLoi,
 *   defaultUnderwriting) cache in STATIC fields. Statics are wiped between the
 *   @TestSetup transaction and each test-method transaction.
 *
 *   Therefore: if @TestSetup calls default*() and a test method ALSO calls
 *   default*(), the test method SILENTLY CREATES A SECOND RECORD. It does not
 *   reuse the @TestSetup one. Counts drift, rollups look wrong, and the failure
 *   surfaces far from its cause.
 *
 *     // WRONG — creates a second Property_Asset__c
 *     @TestSetup static void setup() { TestDataFactory.createWorkOrders(251, true); }
 *     @isTest static void t() { Id a = TestDataFactory.defaultPropertyAsset().Id; ... }
 *
 *     // RIGHT — query for what @TestSetup created
 *     @isTest static void t() { Id a = [SELECT Id FROM Property_Asset__c LIMIT 1].Id; ... }
 *
 *   Rule: NEVER call default*() in a test method if @TestSetup already built data.
 *   Query for it instead. Within a single transaction the cache is stable and safe.
 *
 * ⚠ 2. FOUR FIELDS ARE TYPE-INVERTED AGAINST THEIR OWN NAMES.
 *
 *   - Disposition__c.Package_Sent__c        is a DATE     (sounds Boolean)
 *   - Transaction__c.Is_Wire_Approval_Due__c is a CHECKBOX (sounds like a Date)
 *   - Counter_Offer__c.Revision_Number__c   is TEXT       (says "Number")
 *   - Deal_Message__c.Revision__c           is TEXT       (sounds like a Number)
 *
 *   Do not type from the field name — check the metadata. This factory got all
 *   four wrong on the first pass WITH the metadata open; the compiler caught them.
 *   `Revision_Number__c` typed as Text is the sharpest case: the name contains the
 *   word "Number" and it is not one. This defect class is the evidence behind the
 *   type-suffix rule in ARCHITECTURE.md §1.
 *
 *   Related: seven money/duration fields are TEXT, not Currency/Number, against
 *   ARCHITECTURE.md §1's naming convention — Lease_Inquiry__c.Base_Rent__c,
 *   .TI_Allowance__c; Lease_Renewal__c.Current_Rent__c;
 *   Development_Feasibility_Review__c.Est_Cost_Impact__c, .Proposals_Target__c;
 *   Construction_Feasibility_Review__c.Estimated_Timeline_Impact__c;
 *   CAM_Reconciliation__c.Reconciliation_Year__c. They take String literals here.
 *
 * ⚠ 3. FIVE OBJECTS HAVE RECORD TYPES AND THE FACTORY STAMPS ALL FIVE.
 *   (This note said TWO until 2026-08-09; NDA__c arrived in Tranche 3A, LOI__c in 3B and
 *   Contract_Review__c in 3C.)
 *
 *   - Opportunity -> createOpportunitiesByRecordType (Land / Retail)
 *   - Disposition__c -> createDispositions (On_Market by default; Off_Market via the
 *     4-argument overload or createDisposition(assetId, rtName, doInsert))
 *   - NDA__c -> createNdas (Acquisition_NDA by default; Disposition_NDA via the
 *     4-argument overload or createDispositionNda(dispositionId, doInsert))
 *   - LOI__c -> createLois (Acquisition_LOI by default; Disposition_LOI via the
 *     4-argument overload or createDispositionLoi(dispositionId, doInsert))
 *   - Contract_Review__c -> createContractReviews (Acquisition_PSA by default; Disposition_PSA
 *     via the 4-argument overload or createDispositionContractReview(dispositionId, doInsert))
 *
 *   An UNSTAMPED record inherits the TEST-RUNNING USER'S PROFILE DEFAULT, which is org
 *   state and not deployable (`profiles/**` is .forceignore'd) — so an unstamped fixture
 *   is green or red depending on who runs the suite. All five stamps are guarded on
 *   isAvailable(), so they degrade to the platform default in an org where the record types
 *   have not deployed rather than turning every affected test red.
 *
 *   ⚠ ALL FOUR CUSTOM OBJECTS SEED A PER-RECORD-TYPE STARTING PICKLIST VALUE, and that is not
 *   cosmetic.
 *   ⚠ RETRACTED 2026-08-21 — the reason given was "record-type picklist restriction is enforced
 *   by the UI ONLY, so Apex DML would happily insert an off-set value and produce a fixture
 *   RecordStageAdvanceService cannot advance." All four fields are `restricted`, so DML enforces
 *   the record type's subset (measured; RecordStageAdvanceService's class header). A wrong seed
 *   therefore does NOT produce a quietly-broken fixture — it fails the INSERT with
 *   INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and reds every test using that factory method, which
 *   is a better failure and an easier one to read. The per-type seeds are still mandatory; only
 *   the predicted symptom changes. 🔴 One consequence is NOT cosmetic: because this factory is
 *   shared, a seed that names a value a record type has not been DEPLOYED with takes the whole
 *   suite down at once. Deploy order (record type before factory) is a hard requirement here.
 *   NDA__c: 'Pending' vs 'Prepare' (⚠ the disposition seed was 'Not Sent' until 2026-08-25, when
 *   the user removed that value from the Disposition_NDA record type in Setup). LOI__c: 'Draft' vs 'Received' (no shared
 *   STARTING value to fall back on — ⚠ this said "fully disjoint sets" until 2026-08-14, which
 *   observation 5 ended by renaming 'Prepare/Review' to 'Under Review', a value the disposition
 *   sequence already carried; the sets now OVERLAP there, and only the seeds are still
 *   per-type). Contract_Review__c: 'Draft' vs
 *   'Initial Draft'. Disposition__c seeds 'Disposition Readiness', which is valid on both of its
 *   types.
 *
 *   🔴 Contract_Review__c WAS THE ONE EXCEPTION UNTIL 2026-08-14 AND IS NO LONGER. This block used
 *   to read: "Its two record types expose the IDENTICAL Negotiation_Status__c and Stage__c value
 *   sets (stated deliberately in Disposition_PSA's own record type file), so there is no per-type
 *   seed to choose and a branch would invent a difference that does not exist." That was true when
 *   written; Acquisition Observations phase 3 (observation 7) SPLIT the Negotiation_Status__c
 *   sequences — acquisition `Draft -> Negotiation -> Signed -> Executed`, disposition
 *   `Initial Draft -> Revised -> Ready for Execution -> Executed` — leaving 'Executed' as the only
 *   shared value and no shared STARTING value at all. Do not restore the retracted sentence; see
 *   createContractReviews' own header for the full argument and for why the field-level default
 *   must NOT be moved instead. What ALSO differs between its types, and is still not the factory's
 *   business, is the PERMISSION GATE — that is not a field on the row.
 *
 * ── CONVENTIONS ──────────────────────────────────────────────────────────────
 *  - Every object exposes createXs(count, [parents], doInsert) returning a List,
 *    and a singular createX([parents], doInsert) that delegates to the bulk form.
 *  - `doInsert = false` returns unsaved records so callers can mutate before DML.
 *  - Bulk methods build in memory and perform exactly ONE DML at the end — they
 *    are safe to call with 251+ per .claude/rules/bulk-test-rule.md.
 *  - Callers customise via applyOverrides(records, Map<String,Object>) rather than
 *    the factory growing a method per field permutation.
 *  - Child objects that hang off a hub parent also expose a no-parent overload
 *    which lazily builds a shared scaffold (see defaultPropertyAsset() et al), so
 *    a 251-record setup is a single line.
 *
 * ── SCHEMA FACTS THIS FACTORY ENCODES (verified against force-app metadata) ───
 *  - 31 of 33 custom objects use an AutoNumber Name. Name is NEVER set on them;
 *    only Property__c and Property_Asset__c have a writeable Text Name.
 *  - Formula / rollup fields are never assigned (they are not writeable).
 *  - 5 Master-Detail parents are mandatory: Unit__c.Property_Asset__c,
 *    Rent_Step__c.Unit__c, Lease_Activity__c.Lease_Inquiry__c,
 *    Renewal_Activity__c.Lease_Renewal__c, Work_Order_Activity__c.Work_Order__c.
 *  - Deal_Message__c has an active validation rule (Exactly_One_Parent): exactly
 *    one of LOI__c / Underwriting__c / Contract_Review__c. Hence three methods.
 *  - Broker__c lookups on Broker_Assignment__c and Lease_Inquiry__c carry an
 *    active lookup filter requiring Contact.Is_Broker__c = true — use
 *    createBrokerContacts(), not createContacts().
 *  - The 4 Yardi mirror external ids are unique; they use a static counter so
 *    repeated factory calls in one transaction cannot collide.
 *  - Task links to Transaction__c via Transaction_Deal__c (defined on the Activity
 *    object folder), NOT WhatId.
 *
 * ── CASCADES CALLERS MUST KNOW ABOUT ─────────────────────────────────────────
 *  Inserting an Opportunity fires OpportunityReviewTrigger:
 *    - ensureNda() always creates one NDA__c and re-updates the Opportunity.
 *    - StageName 'Under Contract (PSA)' also creates a Contract_Review__c (+ Opp update).
 *    - StageName 'Underwriting' also creates an Underwriting__c (+ Opp update).
 *    - 'Development Review' / 'Construction Review' create feasibility reviews.
 *  Default stage is therefore 'New' (valid in both business processes) to keep
 *  the blast radius to the unavoidable NDA. Tests asserting NDA__c counts must
 *  account for the auto-created one.
 *
 *  ⚠ MOVING a saved Opportunity between stages now crosses VALIDATION-RULE GATES
 *  (signed NDA / approved underwriting / approved LOI / signed contract, plus a
 *  backward-movement block). Setting StageName BEFORE insert still bypasses them
 *  all, because ISCHANGED() is false on insert. To cross a gate legitimately, use
 *  the four stage-gate helpers next to createOpportunitiesByRecordType:
 *  signPrimaryNda / approveUnderwriting / placeApprovedLoi / signContract.
 *
 * ── DELIBERATE DEVIATION ─────────────────────────────────────────────────────
 *  This class exceeds the sf-apex 500-line guidance. That rule targets
 *  single-responsibility production classes; ARCHITECTURE.md §2 names exactly one
 *  factory at exactly this path, and Phase 2 migrates 44 test classes onto it.
 *  Splitting it would contradict the doc and the migration. Responsibility is
 *  still singular: test-data construction.
 *
 * @see .claude/rules/bulk-test-rule.md
 * @see .claude/skills/sf-apex-test/references/test-data-factory.md
 */
@isTest
public with sharing class TestDataFactory {

    // ═══════════════════════════════════════════════════════════════════════════
    // INFRASTRUCTURE
    // ═══════════════════════════════════════════════════════════════════════════

    /** Monotonic per-transaction counter. Backs values on fields with a UNIQUE
     *  constraint so two factory calls in one transaction cannot collide. */
    private static Integer uniqueCounter = 0;

    private static Integer nextUnique() {
        return uniqueCounter++;
    }

    /**
     * Applies field overrides to every record in a collection.
     * @param records   Records to mutate (may be unsaved).
     * @param overrides Field API name -> value.
     * @example
     * List<Work_Order__c> wos = TestDataFactory.createWorkOrders(251, false);
     * TestDataFactory.applyOverrides(wos, new Map<String, Object>{ 'Status__c' => 'Closed' });
     * insert wos;
     */
    public static void applyOverrides(List<SObject> records, Map<String, Object> overrides) {
        if (records == null || records.isEmpty() || overrides == null || overrides.isEmpty()) {
            return;
        }
        for (SObject record : records) {
            for (String fieldName : overrides.keySet()) {
                record.put(fieldName, overrides.get(fieldName));
            }
        }
    }

    /**
     * Single-record convenience form of applyOverrides.
     * @param record    Record to mutate.
     * @param overrides Field API name -> value.
     */
    public static void applyOverrides(SObject record, Map<String, Object> overrides) {
        if (record == null) {
            return;
        }
        applyOverrides(new List<SObject>{ record }, overrides);
    }

    /** Single DML for a whole collection. Never called inside a loop. */
    private static void insertIf(Boolean doInsert, List<SObject> records) {
        if (doInsert == true && !records.isEmpty()) {
            insert records;
        }
    }

    /**
     * Inserts records that are DELIBERATELY duplicate-shaped, telling the org's duplicate rules to
     * alert-but-save instead of blocking.
     *
     * ── WHY THIS EXISTS (added 2026-08-03) ────────────────────────────────────────────────────
     * `Standard_Account_Duplicate_Rule` and `Standard_Contact_Duplicate_Rule` are ACTIVE BY DESIGN
     * in this org and are deliberately left that way (they protect every UI-driven creation path;
     * see the D4 discussion in LeadConvertActionService). They are `actionOnInsert=Allow` /
     * `operationsOnInsert=Alert,Report` — "warn a human, let them continue" — but Apex DML has no
     * surface on which to render an alert, so the platform degrades "Alert" into a hard
     * DUPLICATES_DETECTED and the insert fails.
     *
     * That bites any test that must SEED duplicate-shaped rows on purpose — a tie-break test needs
     * two Accounts with the same Name, or two Contacts with the same Email, and cannot be written
     * any other way. `DuplicateRuleHeader.allowSave` is the platform's supported mechanism for
     * exactly this, and unlike lead conversion (where the setters on Database.LeadConvert are
     * required because DML options do not reach the records conversion creates) a PLAIN insert DOES
     * honour it.
     *
     * ⚠ SCOPE — this is NOT related to Smart Lead Conversion's D4 bypass. That bypass covers
     * records created BY A CONVERSION only; it does nothing for ordinary test seeding. Two separate
     * mechanisms, two separate reasons.
     *
     * ⚠ IT DOES NOT WEAKEN ANY ASSERTION. `allowSave` only suppresses the duplicate BLOCK at insert
     * time; it changes nothing about the rows themselves, so a tie-break test still gets exactly
     * the two same-named / same-emailed rows it asked for and still discriminates on CreatedDate
     * and Id. `optAllOrNone` stays TRUE so a genuine failure (bad field, validation rule, missing
     * required value) still throws loudly — this helper suppresses duplicate alerts, not errors.
     *
     * ⚠ FUZZY MATCHING IS WIDER THAN "IDENTICAL". The standard Account rule matches on a FUZZY
     * name, so names differing only by a trailing counter — which is exactly what
     * `createAccounts` generates ('Test Account 0-1' vs 'Test Account 0-2') — can match each other.
     * Two separate `createAccount(true)` calls in one transaction are therefore already enough to
     * trip it. Prefer genuinely dissimilar names where the test does not care about the value; use
     * this helper where it does.
     *
     * @param records the duplicate-shaped records to insert; null/empty is a no-op.
     * @example
     * List<Account> firms = TestDataFactory.createAccounts(2, false);
     * TestDataFactory.insertAllowingDuplicates(firms);
     */
    public static void insertAllowingDuplicates(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return;
        }
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        dml.optAllOrNone = true;   // a REAL failure must still throw; only duplicate alerts are suppressed
        Database.insert(records, dml);
    }

    private static void requirePositive(Integer count) {
        if (count == null || count < 1) {
            throw new TestDataFactoryException('count must be a positive integer; received: ' + count);
        }
    }

    /**
     * The Id of a record type by developer name, or null when it does not exist in this org OR
     * is not available to the running user (which, inside System.runAs, is the impersonated user).
     *
     * ⚠ REVERSED 2026-08-10 (fix round 1) — READ BEFORE CHANGING THIS METHOD AGAIN.
     *
     * The first pass of this helper guarded on `info != null` alone, deliberately omitting
     * `isAvailable()`, on the reasoning that "Apex DML writes in system mode regardless, so
     * isAvailable() would never block the write - it would only leave records unstamped."
     * That reasoning was WRONG and was falsified by a live reproduction, not by inspection:
     *
     *   ContactSelectorTest.selectBrokersOrderedByName_standardUserWithGrants_userModeReturnsRows
     *   System.DmlException: INVALID_CROSS_REFERENCE_KEY, Record Type ID: this ID value isn't
     *   valid for the user: 012iw0000009xtjAAA: [RecordTypeId]
     *     Class.TestDataFactory.insertIf: line 161
     *     Class.TestDataFactory.createBrokerContacts: line 504
     *
     * That insert is a PLAIN `insert records;` - no WITH USER_MODE, no AccessLevel.USER_MODE
     * anywhere in its path - which is already the CRUD/FLS-bypassing default every other DML
     * statement in this factory uses, executed inside System.runAs(standardUser). It still threw.
     * Record-type visibility is enforced by a layer the AccessLevel enum does not reach: it is
     * checked against the EFFECTIVE RUNNING USER's profile/permission-set record-type
     * assignments at DML time, for every insert/update of that record's type, independent of
     * whether the surrounding DML is CRUD/FLS-checked (WITH USER_MODE) or CRUD/FLS-bypassing
     * (the default, or AccessLevel.SYSTEM_MODE) - AccessLevel governs CRUD, FLS and sharing only.
     * Assigning a RecordTypeId the running user cannot access throws INVALID_CROSS_REFERENCE_KEY
     * unconditionally; there is no DML mode that downgrades that into "insert succeeds, unstamped."
     *
     * So the real choice was never "throws vs. silently unstamped" - it was always "throws vs.
     * doesn't set RecordTypeId at all," and only `isAvailable()` can tell those apart before the
     * DML fires. Guarding on `info != null` alone described an outcome (a quietly unstamped
     * record) that this DML layer cannot actually produce for an unavailable-but-existing record
     * type; the actual failure mode is a hard exception, in the transaction of whichever test (or
     * later, production principal) is under-provisioned - the same shape as this repo's
     * ContentPublication incident (see ARCHITECTURE.md §2, InboundEmailAttachmentService), where
     * an unconditional write became a single point of failure for a transaction that had nothing
     * to do with the write's own purpose.
     *
     * Null is therefore a legitimate answer for TWO reasons, not one: the record type does not
     * exist in this org (lets Tasks 1 and 3 land in either order), OR it exists but is not
     * available to the running user - in which case the caller leaves RecordTypeId unset and the
     * platform applies whichever default record type IS available to that user, so a
     * deliberately under-provisioned test persona (this codebase's `*_minimumAccessUserNoFLS_*`
     * pattern is pervasive - see TaskSelectorTest, OnboardingTaskRollupServiceTest,
     * TaskRollupServiceTest) can still call createLead/createAccount/createContact without the
     * factory itself becoming a new, unrelated point of failure for a test whose entire purpose
     * is to exercise that restricted persona.
     *
     * `isAvailable()` reflects the CONTEXT user, and inside System.runAs the context user is the
     * impersonated one - this is the same mechanism every FLS/permission probe in this suite
     * already depends on (PermissionSetAssignmentSelector, UserSelector, the whole
     * `WITH USER_MODE` testing pattern), so it needs no new proof here; verified for the admin
     * test-running user specifically (System Administrator returns isAvailable() = true for all
     * three record types), so this reinstatement does not regress
     * TestDataFactoryTest.factoryStampsAcquisitionSideRecordTypes, which runs as that user.
     *
     * A describe, not a query - it costs no SOQL, which matters because this runs inside every
     * governor-pinned test in the suite.
     */
    private static Id recordTypeId(Schema.SObjectType sobjType, String developerName) {
        Schema.RecordTypeInfo info = sobjType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    private static void requireId(Id value, String label) {
        if (value == null) {
            throw new TestDataFactoryException(label + ' is required and cannot be null.');
        }
    }

    /**
     * Reject an Id that is not of the expected SObject type.
     *
     * Added 2026-08-03 alongside the Competing_Broker_Submission__c winner anchor, which is the
     * factory's first method taking TWO Id parameters that differ only in which object they point
     * at (`winningLeadId`, `winningOpportunityId`). Positional Ids of the same Apex type are
     * trivially transposable at a call site and would compile silently — the same hazard
     * EmailToLeadService.LeadRequest's Javadoc cites for its DTO. Checking the prefix turns a
     * transposition into an immediate, named failure instead of a confusing DML error.
     *
     * @param value    The Id to check; null is allowed (use requireId for presence).
     * @param expected The SObject type it must belong to.
     * @param label    Parameter name for the error message.
     */
    private static void requireSObjectType(Id value, Schema.SObjectType expected, String label) {
        if (value != null && value.getSObjectType() != expected) {
            throw new TestDataFactoryException(
                label + ' must be a ' + expected + ' Id but was a ' + value.getSObjectType()
                + ' Id. Check the argument order.');
        }
    }

    /** Thrown when the factory is asked for something it cannot legally build. */
    public class TestDataFactoryException extends Exception {}

    // ═══════════════════════════════════════════════════════════════════════════
    // LAZY SCAFFOLD
    //
    // Hub parents cached per transaction so child factories can offer a
    // parentless overload. NOTE: statics do not survive the @TestSetup ->
    // test-method transaction boundary, so a test method calling defaultX()
    // after an @TestSetup that also called it will get a SECOND record. Query
    // for @TestSetup-created data instead of relying on the cache across it.
    // ═══════════════════════════════════════════════════════════════════════════

    private static Property__c cachedProperty;
    private static Property_Asset__c cachedPropertyAsset;
    private static Opportunity cachedOpportunity;
    private static Transaction__c cachedTransaction;
    private static Disposition__c cachedDisposition;
    private static Lease_Inquiry__c cachedLeaseInquiry;
    private static Lease_Renewal__c cachedLeaseRenewal;
    private static Unit__c cachedUnit;
    private static Meter__c cachedMeter;
    private static Work_Order__c cachedWorkOrder;
    private static Contract_Review__c cachedContractReview;
    private static LOI__c cachedLoi;
    private static Underwriting__c cachedUnderwriting;
    private static Contact cachedBrokerContact;

    /** Shared inserted Property__c for this transaction. */
    public static Property__c defaultProperty() {
        if (cachedProperty == null) {
            cachedProperty = createProperties(1, true)[0];
        }
        return cachedProperty;
    }

    /** Shared inserted Property_Asset__c (under defaultProperty). */
    public static Property_Asset__c defaultPropertyAsset() {
        if (cachedPropertyAsset == null) {
            cachedPropertyAsset = createPropertyAssets(1, defaultProperty().Id, true)[0];
        }
        return cachedPropertyAsset;
    }

    /** Shared inserted Unit__c (under defaultPropertyAsset). */
    public static Unit__c defaultUnit() {
        if (cachedUnit == null) {
            cachedUnit = createUnits(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedUnit;
    }

    /** Shared inserted Meter__c (under defaultPropertyAsset, whole-building, 5-dial). */
    public static Meter__c defaultMeter() {
        if (cachedMeter == null) {
            cachedMeter = createMeters(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedMeter;
    }

    /** Shared inserted Opportunity at stage 'New'. Note: this also creates an NDA__c. */
    public static Opportunity defaultOpportunity() {
        if (cachedOpportunity == null) {
            cachedOpportunity = createOpportunities(1, true)[0];
        }
        return cachedOpportunity;
    }

    /** Shared inserted Transaction__c. */
    public static Transaction__c defaultTransaction() {
        if (cachedTransaction == null) {
            cachedTransaction = createTransactions(1, true)[0];
        }
        return cachedTransaction;
    }

    /** Shared inserted Disposition__c (under defaultPropertyAsset). */
    public static Disposition__c defaultDisposition() {
        if (cachedDisposition == null) {
            cachedDisposition = createDispositions(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedDisposition;
    }

    /** Shared inserted Lease_Inquiry__c (under defaultPropertyAsset). */
    public static Lease_Inquiry__c defaultLeaseInquiry() {
        if (cachedLeaseInquiry == null) {
            cachedLeaseInquiry = createLeaseInquiries(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedLeaseInquiry;
    }

    /** Shared inserted Lease_Renewal__c (under defaultPropertyAsset). */
    public static Lease_Renewal__c defaultLeaseRenewal() {
        if (cachedLeaseRenewal == null) {
            cachedLeaseRenewal = createLeaseRenewals(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedLeaseRenewal;
    }

    /** Shared inserted Work_Order__c (under defaultPropertyAsset). */
    public static Work_Order__c defaultWorkOrder() {
        if (cachedWorkOrder == null) {
            cachedWorkOrder = createWorkOrders(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedWorkOrder;
    }

    /** Shared inserted Contract_Review__c (under defaultOpportunity). */
    public static Contract_Review__c defaultContractReview() {
        if (cachedContractReview == null) {
            cachedContractReview = createContractReviews(1, defaultOpportunity().Id, true)[0];
        }
        return cachedContractReview;
    }

    /** Shared inserted LOI__c (under defaultOpportunity). */
    public static LOI__c defaultLoi() {
        if (cachedLoi == null) {
            cachedLoi = createLois(1, defaultOpportunity().Id, true)[0];
        }
        return cachedLoi;
    }

    /** Shared inserted Underwriting__c (under defaultOpportunity). */
    public static Underwriting__c defaultUnderwriting() {
        if (cachedUnderwriting == null) {
            cachedUnderwriting = createUnderwritings(1, defaultOpportunity().Id, true)[0];
        }
        return cachedUnderwriting;
    }

    /**
     * Shared inserted broker Contact (Is_Broker__c = true) for this transaction.
     *
     * Added 2026-08-20 (requirements §3 D1) so `createBovSubmissions`' SINGULAR convenience path
     * can satisfy `BOV_Submission__c.Broker_Required_On_Submission` without a caller that loops
     * over `createBovSubmission(...)` many times in one transaction (measured pattern:
     * `BovSubmissionSelectionGuardTest.bulk251BecomingSelected...`, `BovSubmissionTriggerHandlerTest
     * .bulk251ApprovesAtConstantCost`, both of which call the singular method 251 times) blowing the
     * 150-DML-statement limit on 251 separate Contact inserts. A genuine BULK caller
     * (`createBovSubmissions(251, ...)`) does NOT use this cache — see `brokerContactIdsFor` — and
     * gets 251 distinct brokers in exactly one extra INSERT instead.
     *
     * ⚠ Same @TestSetup-boundary caveat as every other default*() accessor: the cache does not
     * survive from @TestSetup into a test method. See the class header's warning #1.
     */
    public static Contact defaultBrokerContact() {
        if (cachedBrokerContact == null) {
            cachedBrokerContact = createBrokerContacts(1, null, true)[0];
        }
        return cachedBrokerContact;
    }

    /**
     * Clears the cached scaffold. Call when a test needs a genuinely fresh graph
     * within the same transaction.
     */
    public static void resetScaffold() {
        cachedProperty = null;
        cachedPropertyAsset = null;
        cachedOpportunity = null;
        cachedTransaction = null;
        cachedDisposition = null;
        cachedLeaseInquiry = null;
        cachedLeaseRenewal = null;
        cachedUnit = null;
        cachedWorkOrder = null;
        cachedContractReview = null;
        cachedLoi = null;
        cachedUnderwriting = null;
        cachedBrokerContact = null;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STANDARD OBJECTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count    Number of Accounts.
     * @param doInsert Insert when true.
     * @return Accounts with unique Names (Account duplicate rule is Alert/Allow,
     *         but unique names keep matching-rule noise out of test output).
     */
    public static List<Account> createAccounts(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(
                Name = 'Test Account ' + i + '-' + nextUnique(),
                BillingCity = 'Houston',
                BillingState = 'TX',
                BillingCountry = 'USA',
                Phone = '713-555-' + String.valueOf(i).leftPad(4, '0')
            ));
        }
        Id brokerFirmRt = recordTypeId(Account.SObjectType, 'Broker_Firm');
        if (brokerFirmRt != null) {
            for (Account a : accounts) {
                a.RecordTypeId = brokerFirmRt;
            }
        }
        insertIf(doInsert, accounts);
        return accounts;
    }

    /** Single Account. @param doInsert Insert when true. @return The Account. */
    public static Account createAccount(Boolean doInsert) {
        return createAccounts(1, doInsert)[0];
    }

    /**
     * @param count     Number of Contacts.
     * @param accountId Parent Account; may be null (Contact.AccountId is optional).
     * @param doInsert  Insert when true.
     * @return Contacts.
     */
    public static List<Contact> createContacts(Integer count, Id accountId, Boolean doInsert) {
        requirePositive(count);
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < count; i++) {
            Integer u = nextUnique();
            contacts.add(new Contact(
                FirstName = 'Test',
                LastName = 'Contact ' + i,
                Email = 'test.contact' + u + '@example.invalid',
                Phone = '713-555-' + String.valueOf(i).leftPad(4, '0'),
                AccountId = accountId
            ));
        }
        Id brokerRt = recordTypeId(Contact.SObjectType, 'Broker');
        if (brokerRt != null) {
            for (Contact c : contacts) {
                c.RecordTypeId = brokerRt;
            }
        }
        // AllowSave, not insertIf: LastName is generated from the LOOP INDEX ('Test Contact 0',
        // 'Test Contact 1', ...), which resets to 0 on every call — it is not a transaction-wide
        // counter the way nextUnique() (used for Email) is. Two separate createContacts/
        // createBrokerContacts/createBrokerContactWithFirm calls in the same test method routinely
        // produce a second "Test Contact 0" with the same Phone shape as the first call's first row,
        // which the org's active Standard_Contact_Duplicate_Rule (Alert/Allow, degraded by Apex DML
        // into a hard DUPLICATES_DETECTED) then refuses. Test data is deliberately exempt from that
        // rule — see insertAllowingDuplicates's header. This is NOT "making the data more unique";
        // it states the intent that duplicate-shaped test fixtures are allowed to save.
        insertContactsIf(doInsert, contacts);
        return contacts;
    }

    /** Contact-specific insertIf: routes through insertAllowingDuplicates (see createContacts). */
    private static void insertContactsIf(Boolean doInsert, List<Contact> contacts) {
        if (doInsert == true && !contacts.isEmpty()) {
            insertAllowingDuplicates(contacts);
        }
    }

    /** Single Contact. @param accountId Parent Account (nullable). @param doInsert Insert when true. @return The Contact. */
    public static Contact createContact(Id accountId, Boolean doInsert) {
        return createContacts(1, accountId, doInsert)[0];
    }

    /**
     * Contacts that are GENUINELY NOT BROKERS — added 2026-08-20, when the broker definition moved
     * from `Contact.Is_Broker__c = true` to the `Contact.Broker` RECORD TYPE.
     *
     * ══ 🔴 WHY THIS EXISTS: `createContacts` IS NOT A NON-BROKER FIXTURE AND NEVER WAS ══
     * `createContacts` STAMPS THE BROKER RECORD TYPE on every row it produces (see its body,
     * unchanged since the 2026-08-10 IR segregation). It merely leaves `Is_Broker__c` at its
     * `false` default. That made it *look* like a non-broker fixture for as long as the checkbox
     * was the definition, and several tests used it as their "no brokers exist" / "a non-broker
     * must be excluded" control while asserting an empty or reduced result.
     *
     * The instant the definition moved to the record type, every one of those controls INVERTED:
     * the fixture became a positive, and the assertions that were meant to prove EXCLUSION began
     * proving nothing (or failing outright). Those tests were repointed here rather than deleted —
     * they are the only proof the broker selectors exclude non-brokers, which is precisely the
     * property that has to keep holding.
     *
     * 🔴 DO NOT "SIMPLIFY" A NON-BROKER FIXTURE BACK TO `createContacts(...)`. It produces brokers.
     *
     * ── WHY BOTH HALVES ARE SET, AND WHY `RecordTypeId = null` IS A CORRECT ANSWER ──
     * `Is_Broker__c` is forced to `false` and the record type is moved OFF Broker, so a row from
     * here fails BOTH the retired and the current definition. That keeps these fixtures valid
     * whichever definition a given test's target happens to be on mid-migration.
     *
     * `recordTypeId(...)` returns null when `Contact.Investor` is unavailable to the running user
     * (see its long header). Assigning null is HARMLESS HERE and is not the silent degradation it
     * is on the broker path: a null RecordTypeId on insert lands the row on the user's DEFAULT
     * record type, which is Master in this org — still NOT Broker, so the fixture's one guarantee
     * ("this Contact is not a broker") holds either way. The broker path cannot make that claim,
     * which is why its degradation needed a paragraph and this one does not.
     *
     * @param count     Number of Contacts.
     * @param accountId Parent Account; may be null.
     * @param doInsert  Insert when true.
     * @return Contacts that are NOT on the Contact.Broker record type and NOT flagged Is_Broker__c.
     * @example
     * // "a non-broker Contact must be excluded from the broker list"
     * TestDataFactory.createNonBrokerContacts(3, null, true);
     */
    public static List<Contact> createNonBrokerContacts(Integer count, Id accountId, Boolean doInsert) {
        List<Contact> contacts = createContacts(count, accountId, false);
        Id investorRt = recordTypeId(Contact.SObjectType, 'Investor');
        for (Contact c : contacts) {
            c.Is_Broker__c = false;
            c.RecordTypeId = investorRt;   // null => the user's default (Master) — also not Broker
        }
        insertContactsIf(doInsert, contacts);
        return contacts;
    }

    /**
     * Single non-broker Contact. See `createNonBrokerContacts` for why `createContact` is NOT a
     * substitute (it stamps the Broker record type).
     * @param accountId Parent Account (nullable). @param doInsert Insert when true.
     * @return A Contact that is not a broker under either the retired or the current definition.
     */
    public static Contact createNonBrokerContact(Id accountId, Boolean doInsert) {
        return createNonBrokerContacts(1, accountId, doInsert)[0];
    }

    /**
     * Broker Contacts. REQUIRED for any `Broker__c` lookup — every one of them carries an ACTIVE,
     * NON-OPTIONAL lookup filter, which the platform enforces on Apex DML and not merely in the UI.
     *
     * ⚠ CORRECTED 2026-08-20. This read: "Contacts flagged Is_Broker__c = true. REQUIRED for any
     * Broker__c lookup: Broker_Assignment__c.Broker__c and Lease_Inquiry__c.Broker__c both carry an
     * active, non-optional lookup filter on Contact.Is_Broker__c." BOTH halves were stale: the
     * lookup filters now test the `Contact.Broker` RECORD TYPE, and there are SIX such lookups in
     * this repo, not two.
     *
     * WHAT ACTUALLY SATISFIES THE FILTER IS THE RECORD-TYPE STAMP APPLIED BY `createContacts`,
     * which this method delegates to — NOT the `Is_Broker__c = true` set in the loop below.
     * 🔴 The checkbox is still set here ON PURPOSE and must not be removed: `Is_Broker__c` is
     * retained (unused) on Contact, several TEST classes still resolve their fixture by querying
     * `WHERE Is_Broker__c = true`, and dropping it would break those without touching a single
     * production predicate. Removing it belongs to the field's separate, deferred retirement.
     *
     * @param count     Number of broker Contacts.
     * @param accountId Parent Account (nullable).
     * @param doInsert  Insert when true.
     * @return Broker Contacts.
     */
    public static List<Contact> createBrokerContacts(Integer count, Id accountId, Boolean doInsert) {
        List<Contact> brokers = createContacts(count, accountId, false);
        for (Integer i = 0; i < brokers.size(); i++) {
            brokers[i].Is_Broker__c = true;
            brokers[i].Broker_Status__c = 'Active';
            brokers[i].Broker_Firm__c = 'Test Brokerage ' + i;
            brokers[i].Broker_License__c = 'LIC-' + String.valueOf(nextUnique()).leftPad(6, '0');
        }
        // See createContacts's header: AllowSave, not insertIf — the same loop-index LastName
        // collision, and this is the path most exposed to it (defaultBrokerContact,
        // createBrokerContact, createBrokerContactWithFirm and bovBrokerContactIdsFor all funnel
        // through here, frequently once per test method, always starting the index at 0).
        insertContactsIf(doInsert, brokers);
        return brokers;
    }

    /** Single broker Contact. @param accountId Parent Account (nullable). @param doInsert Insert when true. @return The broker Contact. */
    public static Contact createBrokerContact(Id accountId, Boolean doInsert) {
        return createBrokerContacts(1, accountId, doInsert)[0];
    }

    /**
     * A broker Contact whose `Broker_Firm__c` is exactly `firm` — added 2026-08-20 (requirements
     * §3 D1) for tests that need a STAMPED `Broker_Firm__c` on a `BOV_Submission__c` /
     * `Disposition__c` to equal a specific literal after insert.
     *
     * `BovSubmissionBrokerStampService` / `DispositionBrokerStampService` overwrite any hand-typed
     * `Broker_Firm__c` the instant `Broker__c` is set (which, since `Broker_Required_On_Submission`
     * / the equivalent Disposition rule, is now EVERY save) — a before-trigger sees the final field
     * values, so the stamp always wins. The only way left to pin a firm literal into the persisted
     * field is through the Contact that IS the stamp's source: point `Broker__c` at a Contact whose
     * OWN `Broker_Firm__c` already reads what the test wants to assert.
     *
     * @param firm     The exact Broker_Firm__c the returned Contact must carry.
     * @param doInsert Insert when true.
     * @return The broker Contact.
     * @example
     * BOV_Submission__c winner = TestDataFactory.createBovSubmission(dispositionId, false);
     * winner.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE', true).Id;
     * insert winner; // Broker_Firm__c stamps to 'CBRE' from the Contact, not from a hand-typed literal
     */
    public static Contact createBrokerContactWithFirm(String firm, Boolean doInsert) {
        Contact broker = createBrokerContact(null, false);
        broker.Broker_Firm__c = firm;
        // See createContacts's header: AllowSave, not insertIf. createBrokerContact(null, false)
        // always builds an UNsaved, un-inserted single Contact whose LastName is 'Test Contact 0'
        // (index resets to 0 every call) — calling this method more than once per test (a common
        // pattern: one broker per competing BOV submission) produces several same-shaped "Test
        // Contact 0" rows in the same transaction.
        insertContactsIf(doInsert, new List<Contact>{ broker });
        return broker;
    }

    /**
     * @param count    Number of Leads.
     * @param doInsert Insert when true.
     * @return Leads at Status 'New' (this org's custom Lead status set is
     *         New / Under Review / Qualified / Converted / Disqualified).
     */
    public static List<Lead> createLeads(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < count; i++) {
            Integer u = nextUnique();
            leads.add(new Lead(
                FirstName = 'Test',
                LastName = 'Lead ' + i,
                Company = 'Test Company ' + i + '-' + u,
                Email = 'test.lead' + u + '@example.invalid',
                Status = 'New',
                Deal_Type__c = 'Retail',
                Asset_Type__c = 'Retail',
                Property_Address__c = i + ' Test Street, Houston, TX',
                Guidance_Price__c = 1000000 + (i * 1000),
                Guidance_Cap_Rate__c = 6.5
            ));
        }
        Id acqRt = recordTypeId(Lead.SObjectType, 'Acquisition_Broker');
        if (acqRt != null) {
            for (Lead l : leads) {
                l.RecordTypeId = acqRt;
            }
        }
        insertIf(doInsert, leads);
        return leads;
    }

    /** Single Lead. @param doInsert Insert when true. @return The Lead. */
    public static Lead createLead(Boolean doInsert) {
        return createLeads(1, doInsert)[0];
    }

    /**
     * Opportunities at StageName 'New' — valid in BOTH the Land and Retail
     * business processes, and the only stage that does not cascade a feasibility
     * review / Contract Review / Underwriting child on insert.
     *
     * WARNING: OpportunityReviewTrigger.ensureNda still creates one NDA__c per
     * Opportunity and re-updates the Opportunity. 251 Opps => 753 DML rows.
     *
     * @param count     Number of Opportunities.
     * @param accountId Parent Account (nullable).
     * @param doInsert  Insert when true.
     * @return Opportunities.
     */
    public static List<Opportunity> createOpportunities(Integer count, Id accountId, Boolean doInsert) {
        requirePositive(count);
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opps.add(new Opportunity(
                Name = 'Test Opportunity ' + i,
                AccountId = accountId,
                StageName = 'New',
                CloseDate = Date.today().addDays(90),
                Amount = 1000000 + (i * 1000),
                Deal_Type__c = 'Retail',
                // ALL THREE Asset_Type__c VALUE SETS ARE NOW ALIGNED (Gap 1, 2026-08-31). This
                // comment used to read "Opportunity.Asset_Type__c uses 'Retail Strip'; Lead/
                // Property use 'Retail'" — that divergence was the defect and it is gone.
                // Lead's 8 == Opportunity's 8 (Retail, Land, Industrial, Office, Multifamily,
                // Mixed-Use, Hospitality, Medical Office), and Property__c carries those 8 plus
                // C-Store and Storage, so Lead ⊂ Opportunity ⊂ Property. A literal here that is
                // not on the Opportunity set is REFUSED by DML (restricted picklist) and reds
                // most of the suite, so change it only in step with the field and BOTH
                // Opportunity record-type blocks.
                Asset_Type__c = 'Retail',
                Asking_Price__c = 1000000 + (i * 1000),
                Guidance_Cap_Rate__c = 6.5
            ));
        }
        insertIf(doInsert, opps);
        return opps;
    }

    /** Opportunities with no Account. @param count Number. @param doInsert Insert when true. @return Opportunities. */
    public static List<Opportunity> createOpportunities(Integer count, Boolean doInsert) {
        return createOpportunities(count, (Id) null, doInsert);
    }

    /** Single Opportunity. @param accountId Parent Account (nullable). @param doInsert Insert when true. @return The Opportunity. */
    public static Opportunity createOpportunity(Id accountId, Boolean doInsert) {
        return createOpportunities(1, accountId, doInsert)[0];
    }

    /**
     * Opportunities on a specific record type. StageName stays 'New' because it is
     * the only stage present in both the Land and Retail business processes;
     * a stage outside the record type's process fails on insert.
     * @param count                  Number of Opportunities.
     * @param recordTypeDeveloperName 'Land' or 'Retail'.
     * @param accountId              Parent Account (nullable).
     * @param doInsert               Insert when true.
     * @return Opportunities.
     */
    public static List<Opportunity> createOpportunitiesByRecordType(
        Integer count,
        String recordTypeDeveloperName,
        Id accountId,
        Boolean doInsert
    ) {
        Schema.RecordTypeInfo info = Schema.SObjectType.Opportunity
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        if (info == null) {
            throw new TestDataFactoryException(
                'Unknown Opportunity record type: ' + recordTypeDeveloperName + '. Expected Land or Retail.'
            );
        }
        List<Opportunity> opps = createOpportunities(count, accountId, false);
        for (Opportunity opp : opps) {
            opp.RecordTypeId = info.getRecordTypeId();
            opp.Deal_Type__c = recordTypeDeveloperName;
        }
        insertIf(doInsert, opps);
        return opps;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OPPORTUNITY STAGE-GATE FIXTURES
    //
    // Four helpers that put an ALREADY-INSERTED deal into the state a stage
    // validation rule demands, so a test that legitimately needs to cross a gate
    // says so in one readable line.
    //
    //   signPrimaryNda      -> a signed primary NDA        (Underwriting / LOI / PSA /
    //                                                       About to Close / Closed Won)
    //   approveUnderwriting -> primary Underwriting Stage__c = 'Approved'
    //                          + UW_Approved__c            (LOI)   ⚠ both, since 2026-08-28
    //   placeApprovedLoi    -> Primary_LOI__c + LOI_Approved__c (PSA)
    //   signContract        -> Contract_Signed__c          (Closed Won)
    //
    // ── WHY HELPERS AND NOT NINE AD-HOC PATCH-UPS ────────────────────────────
    // The gates are one family of rules; when the family changes (a stage added to
    // the NDA list, a new prerequisite) exactly one place should need editing.
    // Each helper also names the BUSINESS state it creates, so a reader of the test
    // sees "this deal has an approved LOI" rather than four opaque field writes.
    //
    // ── CONTRACT ─────────────────────────────────────────────────────────────
    //  - They take SAVED Opportunities. A record with no Id is rejected loudly
    //    rather than silently doing nothing — these prepare a deal that already
    //    exists, they do not build one.
    //  - Bulk-safe: every helper is ONE DML statement per object it touches, with
    //    no SOQL or DML inside a loop, so the 251-record bulk tests can call them.
    //  - They MIRROR every value they write back onto the caller's in-memory
    //    records, so a later `update opps` in the test carries the same values and
    //    cannot silently re-trigger a "changed to meet criteria" flow.
    //  - DML is done through minimal `new Opportunity(Id = ...)` shells so a helper
    //    can never write back a stale field the caller happens to be holding.
    //
    // ⚠ SIDE EFFECT worth knowing: setting LOI_Approved__c fires the after-save
    //   `LOI_Approval_Stamp` flow (ApprovalAuditService + two group notifications).
    //   With no approval history the audit stamp is a no-op, but the flow does run.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Guard for the stage-gate helpers: they prepare saved deals, so an unsaved record is a
     * caller mistake that must fail by name rather than as a confusing DML error later.
     *
     * @param opportunities The deals to prepare.
     * @param helper        Helper name, for the error message.
     * @return The same list, once every record is known to carry an Id.
     */
    private static List<Opportunity> requireSavedOpportunities(
        List<Opportunity> opportunities,
        String helper
    ) {
        if (opportunities == null || opportunities.isEmpty()) {
            throw new TestDataFactoryException(
                helper + ' requires at least one Opportunity; received null or an empty list.');
        }
        for (Opportunity opp : opportunities) {
            if (opp == null || opp.Id == null) {
                throw new TestDataFactoryException(
                    helper + ' requires INSERTED Opportunities, but one record has no Id. '
                    + 'These helpers prepare a saved deal to cross a stage gate — call them after insert.');
            }
        }
        return opportunities;
    }

    /**
     * Signs each deal's PRIMARY NDA, satisfying the signed-NDA stage gate.
     *
     * ⚠ It SIGNS THE EXISTING RECORD rather than inserting a rival NDA.
     * OpportunityReviewService.ensureNda already opens exactly one Pending NDA per Opportunity on
     * insert and stamps it onto Primary_NDA__c, and the gate reads `Primary_NDA__r.NDA_Signed__c`.
     * Inserting a second, signed NDA would satisfy nothing unless it were also stamped as primary,
     * and would break every test that asserts one NDA per deal. (Same pattern as
     * OpportunityDocStatusControllerTest, which signs the auto-created record in place.)
     *
     * The caller's in-memory copy never carries Primary_NDA__c — the trigger stamps it AFTER the
     * insert returns — so the deals are re-read here. A deal with no primary NDA at all (the
     * cascade was bypassed) gets a signed one created and stamped, so the helper's postcondition
     * is the same either way.
     *
     * @param opportunities Inserted Opportunities to prepare (required, non-empty).
     * @return The NDA records that are now signed, one per deal.
     */
    public static List<NDA__c> signPrimaryNda(List<Opportunity> opportunities) {
        Map<Id, Opportunity> byId =
            new Map<Id, Opportunity>(requireSavedOpportunities(opportunities, 'signPrimaryNda'));

        Map<Id, Id> primaryByDeal = new Map<Id, Id>();
        for (Opportunity saved : [
            SELECT Id, Primary_NDA__c FROM Opportunity WHERE Id IN :byId.keySet()
        ]) {
            primaryByDeal.put(saved.Id, saved.Primary_NDA__c);
        }

        List<NDA__c> signed = new List<NDA__c>();
        List<Opportunity> withoutPrimary = new List<Opportunity>();
        for (Opportunity deal : byId.values()) {
            Id primaryNdaId = primaryByDeal.get(deal.Id);
            if (primaryNdaId == null) {
                withoutPrimary.add(deal);
                continue;
            }
            deal.Primary_NDA__c = primaryNdaId;
            signed.add(new NDA__c(
                Id = primaryNdaId,
                Status__c = 'Signed',
                NDA_Signed__c = true,
                Date_Signed__c = Date.today()
            ));
        }
        if (!signed.isEmpty()) {
            update signed;
        }

        if (!withoutPrimary.isEmpty()) {
            List<NDA__c> replacements = new List<NDA__c>();
            for (Opportunity deal : withoutPrimary) {
                replacements.add(createSignedNdas(1, deal.Id, false)[0]); // build only — no DML in the loop
            }
            insert replacements;
            List<Opportunity> stamps = new List<Opportunity>();
            for (Integer i = 0; i < withoutPrimary.size(); i++) {
                withoutPrimary[i].Primary_NDA__c = replacements[i].Id;
                stamps.add(new Opportunity(
                    Id = withoutPrimary[i].Id, Primary_NDA__c = replacements[i].Id));
            }
            update stamps;
            signed.addAll(replacements);
        }
        return signed;
    }

    /**
     * Signs the primary NDA on one deal.
     * @param opportunity An inserted Opportunity.
     * @return The now-signed NDA.
     */
    public static NDA__c signPrimaryNda(Opportunity opportunity) {
        return signPrimaryNda(new List<Opportunity>{ opportunity })[0];
    }

    /**
     * Marks each deal's underwriting as principal-approved, satisfying the "underwriting approved
     * before LOI" gate.
     *
     * ── ⚠ REPOINTED 2026-08-28 — IT NOW WRITES THE CHILD RECORD TOO ──────────────────────────
     * It used to write ONLY Opportunity.UW_Approved__c, because that was the single field the
     * gate read. The gate moved: Underwriting_Approved_Before_LOI now reads
     * Primary_Underwriting__r.Stage__c, so the flag alone no longer unlocks anything.
     *
     * 🔴 IT WRITES BOTH, AND THAT IS THE POINT — NOT BELT-AND-BRACES. The validation rule is
     * owned by the declarative stream and is being rewritten in parallel with this change. A
     * helper that set only the NEW field would red every caller until that rule ships; a helper
     * that set only the OLD one reds the moment it ships. Setting both means every fixture built
     * through this helper satisfies the gate under EITHER version of the rule, so the two streams
     * can land in either order without a red window. Once the rewritten rule is deployed and
     * verified, UW_Approved__c here is redundant to the gate but is still required by D4 (the
     * deal-level mirror fields are retained and must stay truthful), so do not drop it.
     *
     * Still deliberately does NOT fake UW_Approved_By__c / UW_Approval_Date__c: those are written
     * by ApprovalAuditService from real approval history, and inventing them here would let a test
     * assert an audit trail that no approver ever created. Underwriting_Status__c is likewise left
     * alone — writing it would fire the market-data freeze from a test fixture.
     *
     * ⚠ Contract preserved: no SOQL and no DML inside a loop (the 251-record bulk tests call
     * this). One read, at most two updates and one insert, regardless of batch size.
     *
     * A deal with no Primary_Underwriting__c gets an approved Underwriting created and stamped,
     * so the postcondition is the same either way — the same shape signPrimaryNda uses.
     *
     * @param opportunities Inserted Opportunities to prepare (required, non-empty).
     * @return The same Opportunities, with the flag mirrored onto the in-memory records.
     */
    public static List<Opportunity> approveUnderwriting(List<Opportunity> opportunities) {
        List<Opportunity> deals = requireSavedOpportunities(opportunities, 'approveUnderwriting');

        Map<Id, Opportunity> byId = new Map<Id, Opportunity>(deals);
        Map<Id, Id> primaryByDeal = new Map<Id, Id>();
        for (Opportunity saved : [
            SELECT Id, Primary_Underwriting__c FROM Opportunity WHERE Id IN :byId.keySet()
        ]) {
            primaryByDeal.put(saved.Id, saved.Primary_Underwriting__c);
        }

        List<Underwriting__c> approvals = new List<Underwriting__c>();
        List<Opportunity> withoutPrimary = new List<Opportunity>();
        Map<Id, Opportunity> dealUpdates = new Map<Id, Opportunity>();
        for (Opportunity deal : deals) {
            deal.UW_Approved__c = true;
            dealUpdates.put(deal.Id, new Opportunity(Id = deal.Id, UW_Approved__c = true));

            Id primaryUnderwritingId = primaryByDeal.get(deal.Id);
            if (primaryUnderwritingId == null) {
                withoutPrimary.add(deal);
                continue;
            }
            approvals.add(new Underwriting__c(Id = primaryUnderwritingId, Stage__c = 'Approved'));
        }

        if (!withoutPrimary.isEmpty()) {
            List<Underwriting__c> created = new List<Underwriting__c>();
            for (Opportunity deal : withoutPrimary) {
                // Build only — no DML in the loop.
                created.add(new Underwriting__c(
                    Opportunity__c = deal.Id, Stage__c = 'Approved', Status__c = 'In Progress'));
            }
            insert created;
            for (Integer i = 0; i < withoutPrimary.size(); i++) {
                Id dealId = withoutPrimary[i].Id;
                withoutPrimary[i].Primary_Underwriting__c = created[i].Id;
                dealUpdates.put(dealId, new Opportunity(
                    Id = dealId,
                    UW_Approved__c = true,
                    Primary_Underwriting__c = created[i].Id
                ));
            }
        }

        if (!approvals.isEmpty()) {
            update approvals;
        }
        update dealUpdates.values();
        return deals;
    }

    /**
     * Marks one deal's underwriting as principal-approved.
     * @param opportunity An inserted Opportunity.
     * @return The same Opportunity.
     */
    public static Opportunity approveUnderwriting(Opportunity opportunity) {
        return approveUnderwriting(new List<Opportunity>{ opportunity })[0];
    }

    /**
     * Puts an APPROVED LOI in place on each deal — creates one LOI__c, designates it as
     * Primary_LOI__c and sets LOI_Approved__c — satisfying the "approved LOI before PSA" gate.
     *
     * Both halves are required: the gate reads the lookup AND the flag, because the LOI approval
     * process deliberately leaves the deal parked at the LOI stage, so the flag is the only
     * evidence the approval happened.
     *
     * The returned LOIs are index-aligned to the input, so a caller that needs particular LOI
     * terms can mutate and re-save the record it got back rather than inserting a second LOI
     * (which the controller layer would not read — it prefers Primary_LOI__c).
     *
     * @param opportunities Inserted Opportunities to prepare (required, non-empty).
     * @return The newly created LOIs, one per deal, index-aligned to the input list.
     */
    public static List<LOI__c> placeApprovedLoi(List<Opportunity> opportunities) {
        List<Opportunity> deals = requireSavedOpportunities(opportunities, 'placeApprovedLoi');

        List<LOI__c> lois = new List<LOI__c>();
        for (Opportunity deal : deals) {
            LOI__c loi = createLois(1, deal.Id, false)[0]; // build only — no DML in the loop
            loi.LOI_Status__c = 'Approved';
            lois.add(loi);
        }
        insert lois;

        Map<Id, Opportunity> updates = new Map<Id, Opportunity>();
        for (Integer i = 0; i < deals.size(); i++) {
            deals[i].Primary_LOI__c = lois[i].Id;
            deals[i].LOI_Approved__c = true;
            updates.put(deals[i].Id, new Opportunity(
                Id = deals[i].Id,
                Primary_LOI__c = lois[i].Id,
                LOI_Approved__c = true
            ));
        }
        update updates.values();
        return lois;
    }

    /**
     * Puts an approved LOI in place on one deal.
     * @param opportunity An inserted Opportunity.
     * @return The LOI now designated Primary_LOI__c.
     */
    public static LOI__c placeApprovedLoi(Opportunity opportunity) {
        return placeApprovedLoi(new List<Opportunity>{ opportunity })[0];
    }

    /**
     * Marks each deal's contract as signed (Contract_Signed__c + Contract_Executed_Date__c),
     * satisfying the "contract signed before Closed Won" gate.
     *
     * Mirrors what ContractExecutionService stamps on a real PSA execution, minus the Transaction
     * hand-off: Contract_Executed_Date__c is a DateTime (Day 0) and is set because a signed
     * contract with no execution date is a state the real service never produces.
     *
     * ═══ 🔴 AMENDED 2026-08-17 — THIS HELPER WAS CHEATING, AND A NEW RULE CAUGHT IT ════════════
     * FSD Tranche 1 added Opportunity.Executed_PSA_Before_Contract_Date:
     *     ISCHANGED(Contract_Executed_Date__c) AND NOT(ISBLANK(Contract_Executed_Date__c))
     *     AND NOT(ISBLANK(Primary_Contract__c))
     *     AND TEXT(Primary_Contract__r.Negotiation_Status__c) <> 'Executed'
     * This method wrote Contract_Executed_Date__c directly without ever executing a Contract
     * Review, so the moment a deal legitimately carried a Primary_Contract__c the rule correctly
     * refused the synthetic write with FIELD_CUSTOM_VALIDATION_EXCEPTION ("Contract Executed Date
     * can only be set once the PSA is Executed"). THE RULE IS RIGHT AND THE HELPER WAS WRONG: a
     * hand-typed execution date produces a Day-0 checklist whose 82 deadlines are all silently
     * mis-dated, which is exactly what that rule exists to prevent.
     *
     * The fix reaches the state HONESTLY: executePrimaryContracts() below drives each deal's own
     * primary Contract Review to 'Executed' first — the same transition the deal driver makes via
     * the Advance Stage action — so by the time the stamp lands the rule's premise is satisfied
     * rather than dodged. ContractExecutionService then does the real stamping through the real
     * trigger, and the write below becomes a confirming no-op on those deals.
     *
     * ⚠ BLAST RADIUS IS PROVABLY ZERO FOR EVERY PREVIOUSLY-PASSING CALLER. The new query is
     * filtered `Primary_Contract__c != null`, and a deal with a non-null Primary_Contract__c whose
     * PSA is not Executed is EXACTLY the population the validation rule already rejected. So the
     * new code path is reachable only where this method was already failing: of the 9 call sites
     * (DealFolderServiceTest x3, PropertyAssetServiceTest x2, NdaDealProgressionGateTest,
     * StageAdvanceControllerTest x2, StageAdvanceServiceTest), only the two that enter
     * 'Under Contract (PSA)' — and so get a Contract Review auto-created and stamped by
     * OpportunityReviewService — have a primary contract at all. The other seven pay one extra
     * SOQL and take no behaviour change whatsoever.
     * ⚠ On those two, executing the PSA now also runs the real hand-off: an Offering__c shell is
     * opened and the three GroupNotifier notifications fire. That is correct — it is what a real
     * PSA execution does — but a future caller asserting "no Offering exists" after signContract()
     * on a PSA-stage deal must expect one.
     * ⚠ It does NOT create a Transaction__c: that moved to
     * ContractExecutionService.openTransactionsOnAboutToClose (2026-08-05).
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     *
     * @param opportunities Inserted Opportunities to prepare (required, non-empty).
     * @return The same Opportunities, with both values mirrored onto the in-memory records.
     */
    public static List<Opportunity> signContract(List<Opportunity> opportunities) {
        List<Opportunity> deals = requireSavedOpportunities(opportunities, 'signContract');
        executePrimaryContracts(deals);
        DateTime dayZero = DateTime.now();
        Map<Id, Opportunity> updates = new Map<Id, Opportunity>();
        for (Opportunity deal : deals) {
            deal.Contract_Signed__c = true;
            deal.Contract_Executed_Date__c = dayZero;
            updates.put(deal.Id, new Opportunity(
                Id = deal.Id,
                Contract_Signed__c = true,
                Contract_Executed_Date__c = dayZero
            ));
        }
        update updates.values();
        return deals;
    }

    /**
     * Marks one deal's contract as signed.
     * @param opportunity An inserted Opportunity.
     * @return The same Opportunity.
     */
    public static Opportunity signContract(Opportunity opportunity) {
        return signContract(new List<Opportunity>{ opportunity })[0];
    }

    /**
     * Drives each deal's primary Contract Review to 'Executed', so that the
     * Contract_Executed_Date__c stamp in signContract() is LEGITIMATE rather than a synthetic
     * write that Executed_PSA_Before_Contract_Date correctly refuses. See that method's header
     * for the full rationale and the blast-radius argument.
     *
     * Bulk-safe and conditional by design: ONE query, and ONE DML only when there is something to
     * execute. A deal with no Primary_Contract__c (the majority of callers) is untouched, which is
     * what keeps this change invisible to every previously-passing test.
     *
     * ⚠ 'Executed' is the terminal Negotiation_Status__c value on BOTH the Acquisition_PSA and
     * Disposition_PSA record types, so this is safe on either — the only value of which that is
     * true. Do not substitute a per-record-type value here: Apex DML DOES enforce record-type
     * picklist scoping on this restricted field (measured 2026-08-17).
     */
    private static void executePrimaryContracts(List<Opportunity> deals) {
        Set<Id> dealIds = new Set<Id>();
        for (Opportunity deal : deals) {
            dealIds.add(deal.Id);
        }
        List<Contract_Review__c> toExecute = new List<Contract_Review__c>();
        for (Opportunity deal : [
            SELECT Primary_Contract__c, Primary_Contract__r.Negotiation_Status__c
            FROM Opportunity
            WHERE Id IN :dealIds AND Primary_Contract__c != null
        ]) {
            if (deal.Primary_Contract__r.Negotiation_Status__c != 'Executed') {
                toExecute.add(new Contract_Review__c(
                    Id = deal.Primary_Contract__c,
                    Negotiation_Status__c = 'Executed'
                ));
            }
        }
        if (!toExecute.isEmpty()) {
            update toExecute; // fires ContractReviewTrigger -> the REAL execution hand-off
        }
    }

    /**
     * Day-0 checklist Tasks for a Transaction. These attach via Transaction_Deal__c
     * (NOT WhatId) so they stay off the Activity timeline, and they fire
     * TaskRollupTrigger.
     *
     * NOTE: this method does not cap `count`. TaskFanoutService fans out 82 Tasks
     * per Transaction (82 Transaction_Task_Def__mdt rows across 11 Task_Group_Def__mdt
     * groups — the figure TaskFanoutServiceTest:248 already asserts); 251 Transactions
     * x 82 = 20,582 rows against the 10,000 DML-rows limit. That break is a genuine
     * Phase 7 finding — the factory deliberately does not paper over it by shrinking
     * the fan-out. (This note said "~75 … 18,825" until 2026-08-31 and understated the
     * overflow by 1,757 rows; the count has been 82 since the definitions were loaded.)
     *
     * @param count         Tasks to create.
     * @param transactionId Transaction__c.Id (required).
     * @param doInsert      Insert when true.
     * @return Tasks.
     */
    public static List<Task> createChecklistTasks(Integer count, Id transactionId, Boolean doInsert) {
        requirePositive(count);
        requireId(transactionId, 'transactionId');
        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < count; i++) {
            tasks.add(new Task(
                Subject = 'Test Checklist Task ' + i,
                Status = 'Not Started',
                Priority = 'Normal',
                ActivityDate = Date.today().addDays(14),
                Transaction_Deal__c = transactionId,
                Task_Group__c = 'A. Contract Execution & Title Opening',
                Task_Sequence__c = i + 1
            ));
        }
        insertIf(doInsert, tasks);
        return tasks;
    }

    /** Checklist Tasks against the shared scaffold Transaction. @param count Tasks. @param doInsert Insert when true. @return Tasks. */
    public static List<Task> createChecklistTasks(Integer count, Boolean doInsert) {
        return createChecklistTasks(count, defaultTransaction().Id, doInsert);
    }

    /**
     * Fan-out shaped data: N Tasks for each supplied Transaction, one DML total.
     * @param transactions      Parent Transactions (must be inserted).
     * @param tasksPerTransaction Tasks per Transaction.
     * @param doInsert          Insert when true.
     * @return All Tasks across all Transactions.
     */
    public static List<Task> createChecklistTasksFor(
        List<Transaction__c> transactions,
        Integer tasksPerTransaction,
        Boolean doInsert
    ) {
        requirePositive(tasksPerTransaction);
        List<Task> tasks = new List<Task>();
        for (Transaction__c txn : transactions) {
            requireId(txn.Id, 'Transaction__c.Id (insert Transactions before fanning out Tasks)');
            for (Integer i = 0; i < tasksPerTransaction; i++) {
                tasks.add(new Task(
                    Subject = 'Test Checklist Task ' + i,
                    Status = 'Not Started',
                    Priority = 'Normal',
                    ActivityDate = Date.today().addDays(14),
                    Transaction_Deal__c = txn.Id,
                    Task_Group__c = 'A. Contract Execution & Title Opening',
                    Task_Sequence__c = i + 1
                ));
            }
        }
        insertIf(doInsert, tasks);
        return tasks;
    }

    /**
     * Onboarding checklist Tasks (Property Management module).
     * @param count        Tasks to create.
     * @param onboardingId Onboarding__c.Id (required).
     * @param doInsert     Insert when true.
     * @return Tasks.
     */
    public static List<Task> createOnboardingTasks(Integer count, Id onboardingId, Boolean doInsert) {
        requirePositive(count);
        requireId(onboardingId, 'onboardingId');
        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < count; i++) {
            tasks.add(new Task(
                Subject = 'Test Onboarding Task ' + i,
                Status = 'Not Started',
                Priority = 'Normal',
                ActivityDate = Date.today().addDays(7),
                Onboarding__c = onboardingId,
                Onboarding_Status__c = 'Not Started',
                Source_System__c = 'Salesforce'
            ));
        }
        insertIf(doInsert, tasks);
        return tasks;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY CHAIN
    // Property__c -> Property_Asset__c -> Unit__c (MD) -> Rent_Step__c (MD)
    // Property__c and Property_Asset__c are the ONLY two custom objects with a
    // writeable Text Name; the other 31 are AutoNumber and must never be named.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count    Number of Properties.
     * @param doInsert Insert when true.
     * @return Property__c records (Name is a Text field here, so it is set).
     */
    public static List<Property__c> createProperties(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Property__c> properties = new List<Property__c>();
        for (Integer i = 0; i < count; i++) {
            properties.add(new Property__c(
                Name = 'Test Property ' + i,
                Address__c = i + ' Test Street',
                City__c = 'Houston',
                State__c = 'TX',
                Zip__c = '77001',
                County__c = 'Harris',
                Asset_Type__c = 'Retail',
                Square_Footage__c = 10000 + (i * 100),
                Asking_Price__c = 1000000 + (i * 1000),
                Cap_Rate_Asking__c = 6.5,
                Market_Cap_Rate__c = 6.0,
                Annual_NOI__c = 65000 + (i * 100),
                Year_Built__c = 1995,
                Parcel_ID__c = 'PARCEL-' + String.valueOf(nextUnique()).leftPad(8, '0')
            ));
        }
        insertIf(doInsert, properties);
        return properties;
    }

    /** Single Property. @param doInsert Insert when true. @return The Property__c. */
    public static Property__c createProperty(Boolean doInsert) {
        return createProperties(1, doInsert)[0];
    }

    /**
     * @param count      Number of Property Assets.
     * @param propertyId Parent Property__c (lookup, optional in schema).
     * @param doInsert   Insert when true.
     * @return Property_Asset__c records (Text Name is set).
     */
    public static List<Property_Asset__c> createPropertyAssets(Integer count, Id propertyId, Boolean doInsert) {
        requirePositive(count);
        List<Property_Asset__c> assets = new List<Property_Asset__c>();
        for (Integer i = 0; i < count; i++) {
            assets.add(new Property_Asset__c(
                Name = 'Test Asset ' + i,
                Property__c = propertyId,
                Property_Type__c = 'Retail',
                Status__c = 'Active',
                NOI__c = 65000 + (i * 100),
                Market_Cap_Rate__c = 6.0,
                Argus_Value__c = 1000000 + (i * 1000),
                // 🔴 `Target_Sale_Price__c` IS DELIBERATELY NOT SET — REMOVED 2026-08-25.
                // It used to default to `1200000 + (i * 1000)`. On 2026-08-25 `BOV_Score__c`'s
                // value basis moved from `Disposition__c.Asking_Price__c` (retired) to THIS FIELD,
                // two hops out, which turned this innocuous default into a suite-wide silent
                // inversion: every Disposition under a factory asset became SCOREABLE, so every
                // test whose premise is "a null score is not a rank" — nothing is appointed, the
                // matrix ties at null, the Disposition-Readiness price gate refuses — would have
                // gone on passing while proving the OPPOSITE of what it says. The same class of
                // defect the old default protected against, pointing the other way.
                // ⚠ THE RULE IT RESTORES IS THE ONE `DispositionApprovalServiceTest`'s fixture
                // block already stated: A FIXTURE MUST NOT SATISFY A GATE BY CONSTRUCTION. Do not
                // re-add a default here to make some future test pass — set it AT THE CALL SITE
                // (`createPricedDisposition(...)`, or a plain `update` on the asset) so a reader
                // can see whether the gate is being satisfied or exercised.
                // ⚠ Nothing asserted the old default: `SellMeterControllerTest` and
                // `PropertyAssetSelectorTest` both set their own values (checked 2026-08-25), and
                // `SellMeterController` is null-safe on this field.
                Sell_Readiness_Score__c = 50,
                Vacant_Area__c = 0
            ));
        }
        insertIf(doInsert, assets);
        return assets;
    }

    /** Property Assets under the shared scaffold Property. @param count Number. @param doInsert Insert when true. @return Assets. */
    public static List<Property_Asset__c> createPropertyAssets(Integer count, Boolean doInsert) {
        return createPropertyAssets(count, defaultProperty().Id, doInsert);
    }

    /** Single Property Asset. @param propertyId Parent Property. @param doInsert Insert when true. @return The asset. */
    public static Property_Asset__c createPropertyAsset(Id propertyId, Boolean doInsert) {
        return createPropertyAssets(1, propertyId, doInsert)[0];
    }

    /**
     * Units. Property_Asset__c is a MASTER-DETAIL parent — mandatory.
     * Yardi_Unit_Id__c is a unique external id, so it is counter-backed.
     * @param count           Number of Units.
     * @param propertyAssetId Master Property_Asset__c (required).
     * @param doInsert        Insert when true.
     * @return Units.
     */
    public static List<Unit__c> createUnits(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        requireId(propertyAssetId, 'propertyAssetId (Unit__c.Property_Asset__c is Master-Detail)');
        List<Unit__c> units = new List<Unit__c>();
        for (Integer i = 0; i < count; i++) {
            units.add(new Unit__c(
                Property_Asset__c = propertyAssetId,
                Suite_Number__c = 'Suite ' + (100 + i),
                Tenant_Name__c = 'Test Tenant ' + i,
                Status__c = 'Occupied',
                Square_Feet__c = 1000 + (i * 10),
                Current_Monthly_Rent__c = 5000 + (i * 10),
                Current_Rent_PSF__c = 20,
                Asking_Rent_PSF__c = 22,
                Estimated_NNN_PSF__c = 5,
                Lease_Start__c = Date.today().addMonths(-12),
                Lease_End__c = Date.today().addMonths(12),
                Yardi_Unit_Id__c = 'YU-' + String.valueOf(nextUnique()).leftPad(10, '0')
            ));
        }
        insertIf(doInsert, units);
        return units;
    }

    /** Units under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Units. */
    public static List<Unit__c> createUnits(Integer count, Boolean doInsert) {
        return createUnits(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Unit. @param propertyAssetId Master asset. @param doInsert Insert when true. @return The Unit. */
    public static Unit__c createUnit(Id propertyAssetId, Boolean doInsert) {
        return createUnits(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Rent steps. Unit__c is a MASTER-DETAIL parent — mandatory.
     * Type__c has no picklist default, so it is set explicitly.
     * @param count    Number of Rent Steps.
     * @param unitId   Master Unit__c (required).
     * @param doInsert Insert when true.
     * @return Rent Steps.
     */
    public static List<Rent_Step__c> createRentSteps(Integer count, Id unitId, Boolean doInsert) {
        requirePositive(count);
        requireId(unitId, 'unitId (Rent_Step__c.Unit__c is Master-Detail)');
        List<Rent_Step__c> steps = new List<Rent_Step__c>();
        for (Integer i = 0; i < count; i++) {
            steps.add(new Rent_Step__c(
                Unit__c = unitId,
                Type__c = 'Current Term',
                Period_Label__c = 'Year ' + (i + 1),
                Period_Start__c = Date.today().addMonths(12 * i),
                Period_End__c = Date.today().addMonths(12 * (i + 1)).addDays(-1),
                Monthly_Rent__c = 5000 + (i * 250),
                Rent_PSF__c = 20 + i,
                Sort_Order__c = i + 1
            ));
        }
        insertIf(doInsert, steps);
        return steps;
    }

    /** Rent steps under the shared scaffold Unit. @param count Number. @param doInsert Insert when true. @return Rent Steps. */
    public static List<Rent_Step__c> createRentSteps(Integer count, Boolean doInsert) {
        return createRentSteps(count, defaultUnit().Id, doInsert);
    }

    /** Single Rent Step. @param unitId Master Unit. @param doInsert Insert when true. @return The Rent Step. */
    public static Rent_Step__c createRentStep(Id unitId, Boolean doInsert) {
        return createRentSteps(1, unitId, doInsert)[0];
    }

    /**
     * Builds the full Property -> Asset -> Unit -> Rent_Step chain in 4 DML
     * statements regardless of size. Use this instead of nesting factory calls
     * when a test needs the whole chain populated.
     *
     * Row arithmetic (assert against the 10,000 DML-rows limit before scaling):
     *   rows = 1 + assetCount + (assetCount * unitsPerAsset)
     *            + (assetCount * unitsPerAsset * stepsPerUnit)
     *
     * @param assetCount    Property_Asset__c records under one Property__c.
     * @param unitsPerAsset Unit__c per asset.
     * @param stepsPerUnit  Rent_Step__c per unit.
     * @return Populated graph.
     */
    public static PropertyGraph createPropertyGraph(Integer assetCount, Integer unitsPerAsset, Integer stepsPerUnit) {
        requirePositive(assetCount);
        PropertyGraph graph = new PropertyGraph();
        graph.property = createProperties(1, true)[0];
        graph.assets = createPropertyAssets(assetCount, graph.property.Id, true);

        graph.units = new List<Unit__c>();
        if (unitsPerAsset != null && unitsPerAsset > 0) {
            for (Property_Asset__c asset : graph.assets) {
                graph.units.addAll(createUnits(unitsPerAsset, asset.Id, false));
            }
            insert graph.units;
        }

        graph.rentSteps = new List<Rent_Step__c>();
        if (stepsPerUnit != null && stepsPerUnit > 0 && !graph.units.isEmpty()) {
            for (Unit__c unit : graph.units) {
                graph.rentSteps.addAll(createRentSteps(stepsPerUnit, unit.Id, false));
            }
            insert graph.rentSteps;
        }
        return graph;
    }

    /** Result of createPropertyGraph — the Property chain in one object. */
    public class PropertyGraph {
        public Property__c property;
        public List<Property_Asset__c> assets;
        public List<Unit__c> units;
        public List<Rent_Step__c> rentSteps;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ACQUISITIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /** NDA__c record type developer name for the buy-side NDA (the factory default). */
    public static final String NDA_RT_ACQUISITION = 'Acquisition_NDA';
    /** NDA__c record type developer name for the sell-side NDA. */
    public static final String NDA_RT_DISPOSITION = 'Disposition_NDA';

    /**
     * NDAs on the ACQUISITION record type. Remember OpportunityReviewTrigger.ensureNda already
     * creates one NDA per Opportunity on insert — these are additional.
     * @param count         Number of NDAs.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return NDAs at Status 'Pending', record type Acquisition_NDA.
     */
    public static List<NDA__c> createNdas(Integer count, Id opportunityId, Boolean doInsert) {
        return createNdas(count, opportunityId, NDA_RT_ACQUISITION, doInsert);
    }

    /**
     * NDAs on an explicit record type (D7 / D14.1). Same shape and same reasoning as
     * createDispositions — see that method's header for why the record type is stamped at all
     * rather than inherited from the test-running user's profile default.
     *
     * 🔴 THE SEED STATUS IS CHOSEN BY RECORD TYPE, AND IT HAS TO BE. The two value sets OVERLAP
     * but are not equal: 'Pending' exists only on Acquisition_NDA and 'Prepare' only on
     * Disposition_NDA, so no shared seed value exists.
     * ⚠ AMENDED 2026-08-25 — the disposition seed moved 'Not Sent' -> 'Prepare'. The user removed
     * 'Not Sent' from the Disposition_NDA record type in Setup and cleared that type's default, so
     * 'Not Sent' is now on NO record type and this restricted field REFUSES it at insert. The old
     * seed did not fail a test's assertions — it failed every disposition NDA fixture in the repo
     * at the DML, which is why this one line is load-bearing far outside this method.
     * ⚠ RETRACTED 2026-08-21 — MECHANISM ONLY. This used to continue: "Record-type picklist
     * restriction is UI-only — Apex DML does NOT enforce it — so a shared seed value would insert
     * happily and produce a fixture whose status is off its own record type's value set, which
     * RecordStageAdvanceService would then refuse to advance for reasons no test message would
     * explain." `NDA__c.Status__c` is `restricted`; a shared seed fails at the INSERT instead. See
     * this class's header for the one consequence that is not merely cosmetic (deploy order).
     *
     * ⚠ Party_Role__c is seeded ONLY on the disposition type. On an acquisition DPEG is itself
     * the buyer, so 'Buyer' would name US — the meaning inversion the Acquisition_NDA record type
     * file records, which is why that type carries the values with NO default.
     *
     * ⚠ The stamp is GUARDED on isAvailable(), exactly like createDispositions: an undeployed or
     * unassigned record type leaves RecordTypeId unset rather than turning every NDA test in the
     * repo red. A green suite is therefore NOT proof the record types landed — TestDataFactoryTest
     * and post-deploy gate T-A1 are.
     *
     * @param count                   Number of NDAs.
     * @param opportunityId           Parent Opportunity (nullable).
     * @param recordTypeDeveloperName NDA_RT_ACQUISITION or NDA_RT_DISPOSITION.
     * @param doInsert                Insert when true.
     * @return NDAs seeded at their record type's starting status.
     */
    public static List<NDA__c> createNdas(
        Integer count,
        Id opportunityId,
        String recordTypeDeveloperName,
        Boolean doInsert
    ) {
        requirePositive(count);
        Id recordTypeId = ndaRecordTypeId(recordTypeDeveloperName);
        Boolean isDisposition = NDA_RT_DISPOSITION.equals(recordTypeDeveloperName);
        List<NDA__c> ndas = new List<NDA__c>();
        for (Integer i = 0; i < count; i++) {
            NDA__c nda = new NDA__c(
                Opportunity__c = opportunityId,
                Status__c = isDisposition ? 'Prepare' : 'Pending',
                Counterparty_Name__c = 'Test Counterparty ' + i,
                Method__c = 'DocuSign',
                Date_Sent__c = Date.today(),
                Is_Non_Expiring__c = false,
                NDA_Expiry_Date__c = Date.today().addYears(1)
            );
            if (isDisposition) {
                nda.Party_Role__c = 'Buyer';
            }
            if (recordTypeId != null) {
                nda.RecordTypeId = recordTypeId;
            }
            ndas.add(nda);
        }
        insertIf(doInsert, ndas);
        return ndas;
    }

    /**
     * NDAs parented to a DISPOSITION, on the Disposition_NDA record type — the shape
     * DispositionStageEntryService auto-creates and the shape the off-market all-signed gate
     * counts.
     *
     * ⚠ Party_Role__c is 'Buyer', which is also DispositionStageEntryService's idempotency key.
     * A test that wants to prove auto-create was SUPPRESSED seeds one of these first; a test that
     * wants auto-create to FIRE must not.
     *
     * @param count         Number of NDAs.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return NDAs at Status 'Prepare', Party_Role__c 'Buyer', record type Disposition_NDA.
     */
    public static List<NDA__c> createDispositionNdas(
        Integer count,
        Id dispositionId,
        Boolean doInsert
    ) {
        List<NDA__c> ndas = createNdas(count, null, NDA_RT_DISPOSITION, false);
        for (NDA__c nda : ndas) {
            nda.Disposition__c = dispositionId;
        }
        insertIf(doInsert, ndas);
        return ndas;
    }

    /** Single disposition-parented NDA. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The NDA. */
    public static NDA__c createDispositionNda(Id dispositionId, Boolean doInsert) {
        return createDispositionNdas(1, dispositionId, doInsert)[0];
    }

    /**
     * Signs a BUYER NDA on a disposition, satisfying `All_NDAs_Signed_Before_Progression`'s
     * release gate. Promoted here 2026-08-19 from a private helper of the same name in
     * `DispositionStageEntryServiceTest` (which now delegates to this method) so
     * `ContractExecutionServiceTest` — a different test class — can reuse it rather than
     * re-implementing the same fixture.
     *
     * ⚠ NEEDED SINCE THE 2026-08-19 FLOW REDESIGN dropped that rule's
     * `RecordType.DeveloperName = 'Off_Market'` term, so it now blocks BOTH record types from
     * CHANGING stage into Release Materials / Active Listing / Offer Selection / LOI / PSA /
     * Closing / Sale Closes unless every non-Declined NDA on the disposition is Signed. Any test
     * that performs a real `update` DML into one of those stages needs this precondition first,
     * on-market included; an INSERT straight at a gated stage remains exempt because the rule is
     * `ISCHANGED`-only.
     *
     * Inserted directly at 'Signed' rather than walked through 'Prepare' -> ... -> 'Signed' —
     * `NDA_Signed_Rollup` is `RecordAfterSave` / `CreateAndUpdate`, so it fires on the insert
     * either way and there is nothing to prove about the NDA's own walk here.
     *
     * @param dispositionId An inserted Disposition.
     * @return The newly signed NDA.
     */
    public static NDA__c signBuyerNdaOn(Id dispositionId) {
        NDA__c nda = createDispositionNda(dispositionId, false);
        nda.Status__c = 'Signed';
        insert nda;
        return nda;
    }

    /**
     * Bulk twin of {@link #signBuyerNdaOn(Id)} — ONE insert for the whole set, never one per
     * record, so a 251-disposition bulk fixture stays O(1) in DML statements.
     *
     * @param dispositions Inserted Dispositions to sign a buyer NDA on.
     */
    public static void signBuyerNdasOn(List<Disposition__c> dispositions) {
        List<NDA__c> ndas = new List<NDA__c>();
        for (Disposition__c d : dispositions) {
            NDA__c nda = createDispositionNda(d.Id, false);
            nda.Status__c = 'Signed';
            ndas.add(nda);
        }
        insert ndas;
    }

    /**
     * Resolves an NDA__c record type developer name to its Id, or null when it does not exist in
     * this org / is not available to the running user. An UNRECOGNISED name is a caller mistake
     * and throws, so a typo fails loudly instead of silently producing a default-record-type
     * fixture.
     *
     * 🔴 THE ALLOW-LIST COMPARISON MUST BE CASE-SENSITIVE, AND `!=` IS NOT — the identical trap
     * dispositionRecordTypeId documents at length. Apex `==` / `!=` on String is
     * case-INSENSITIVE while getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY,
     * so with `!=` a name like 'acquisition_nda' would pass the guard, miss the describe map, and
     * silently degrade to the platform default. `String.equals(Object)` is case-sensitive, so
     * guard and lookup answer the same question. Constant-first keeps a null argument on the
     * throw path rather than NPE-ing.
     */
    private static Id ndaRecordTypeId(String recordTypeDeveloperName) {
        if (!NDA_RT_ACQUISITION.equals(recordTypeDeveloperName)
            && !NDA_RT_DISPOSITION.equals(recordTypeDeveloperName)) {
            throw new TestDataFactoryException(
                'Unknown NDA__c record type: ' + recordTypeDeveloperName
                + '. Expected Acquisition_NDA or Disposition_NDA.'
            );
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.NDA__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** Signed NDAs — required to move an Opportunity into Underwriting. @param count Number. @param opportunityId Parent Opp. @param doInsert Insert when true. @return NDAs. */
    public static List<NDA__c> createSignedNdas(Integer count, Id opportunityId, Boolean doInsert) {
        List<NDA__c> ndas = createNdas(count, opportunityId, false);
        for (NDA__c nda : ndas) {
            nda.Status__c = 'Signed';
            nda.NDA_Signed__c = true;
            nda.Date_Signed__c = Date.today();
        }
        insertIf(doInsert, ndas);
        return ndas;
    }

    /** Single NDA. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The NDA. */
    public static NDA__c createNda(Id opportunityId, Boolean doInsert) {
        return createNdas(1, opportunityId, doInsert)[0];
    }

    /** LOI__c record type developer name for the buy-side LOI (the factory default). */
    public static final String LOI_RT_ACQUISITION = 'Acquisition_LOI';
    /** LOI__c record type developer name for the sell-side LOI. */
    public static final String LOI_RT_DISPOSITION = 'Disposition_LOI';

    /**
     * LOIs on the ACQUISITION record type — the shape OpportunityReviewService auto-creates on
     * entry to the LOI stage.
     *
     * @param count         Number of LOIs.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return LOIs at stage 'Draft', record type Acquisition_LOI.
     */
    public static List<LOI__c> createLois(Integer count, Id opportunityId, Boolean doInsert) {
        return createLois(count, opportunityId, LOI_RT_ACQUISITION, doInsert);
    }

    /**
     * LOIs on an explicit record type (D6, Tranche 3B). Same shape and same reasoning as
     * createNdas / createDispositions — see createDispositions' header for why the record type is
     * stamped at all rather than inherited from the test-running user's profile default.
     *
     * 🔴 THE SEED STAGE IS CHOSEN BY RECORD TYPE, AND IT HAS TO BE. The two LOI STARTING values are
     * disjoint — 'Draft' exists only on Acquisition_LOI and 'Received' only on Disposition_LOI — so
     * there is no shared value that would work as a seed for both. ⚠ This used to claim the two
     * value SETS were "FULLY DISJOINT ... with no overlap at all". That ended on 2026-08-14, when
     * observation 5 renamed 'Prepare/Review' to 'Under Review' — a value the disposition sequence
     * already carried — so the sets now overlap there. The seeds do not, which is all this method
     * needs.
     * ⚠ RETRACTED 2026-08-21 — MECHANISM ONLY. This used to continue: "Record-type picklist
     * restriction is UI-only (Apex DML does NOT enforce it), so a hardcoded 'Draft' would insert
     * happily onto a disposition LOI and produce a fixture whose stage is off its own record type's
     * value set, which RecordStageAdvanceService would then refuse to advance for reasons no test
     * message would explain." `LOI__c.Stage__c` is `restricted` and this exact refusal was MEASURED
     * on this field on 2026-08-21 (RecordStageAdvanceService's class header): a hardcoded 'Draft'
     * fails the INSERT. See this class's header for the deploy-order consequence.
     *
     * ⚠ Submitted_Date__c is seeded ONLY on the acquisition type. It is acquisition-directional
     * (DPEG submits the LOI on a purchase; on a sale the LOI ARRIVES from the buyer), and the
     * Disposition_LOI record type file layout-excludes it. Same per-type treatment createNdas
     * gives Party_Role__c.
     *
     * ⚠ The stamp is GUARDED on isAvailable(), exactly like createNdas / createDispositions: an
     * undeployed or unassigned record type leaves RecordTypeId unset rather than turning every LOI
     * test in the repo red. A green suite is therefore NOT proof the record types landed —
     * TestDataFactoryTest and post-deploy gate T-A1 are.
     *
     * @param count                   Number of LOIs.
     * @param opportunityId           Parent Opportunity (nullable).
     * @param recordTypeDeveloperName LOI_RT_ACQUISITION or LOI_RT_DISPOSITION.
     * @param doInsert                Insert when true.
     * @return LOIs seeded at their record type's starting stage.
     */
    public static List<LOI__c> createLois(
        Integer count,
        Id opportunityId,
        String recordTypeDeveloperName,
        Boolean doInsert
    ) {
        requirePositive(count);
        Id recordTypeId = loiRecordTypeId(recordTypeDeveloperName);
        Boolean isDisposition = LOI_RT_DISPOSITION.equals(recordTypeDeveloperName);
        List<LOI__c> lois = new List<LOI__c>();
        for (Integer i = 0; i < count; i++) {
            LOI__c loi = new LOI__c(
                Opportunity__c = opportunityId,
                Stage__c = isDisposition ? 'Received' : 'Draft',
                Offer_Price__c = 1000000 + (i * 1000),
                Offer_Cap_Rate__c = 6.5,
                Earnest_Money__c = 50000,
                Due_Diligence_Days__c = 45,
                Closing_Period_Days__c = 30,
                NOI__c = 65000 + (i * 100),
                Square_Footage__c = 10000 + (i * 100),
                Title_Company__c = 'Test Title Co'
            );
            if (!isDisposition) {
                loi.Submitted_Date__c = Date.today();
            }
            if (recordTypeId != null) {
                loi.RecordTypeId = recordTypeId;
            }
            lois.add(loi);
        }
        insertIf(doInsert, lois);
        return lois;
    }

    /**
     * LOIs parented to a DISPOSITION, on the Disposition_LOI record type — the sell-side
     * negotiation record D6 migrates off Disposition_Offer__c.
     *
     * ⚠ Opportunity__c is left NULL deliberately. A disposition LOI hangs off Disposition__c
     * only, and that lookup is CounterOfferService.isSaleSide's fallback discriminator for the
     * migration window in which every row still sits on the Master record type — a fixture
     * carrying both parents would make the two clauses of that rule indistinguishable.
     *
     * @param count         Number of LOIs.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return LOIs at stage 'Received', record type Disposition_LOI.
     */
    public static List<LOI__c> createDispositionLois(
        Integer count,
        Id dispositionId,
        Boolean doInsert
    ) {
        List<LOI__c> lois = createLois(count, null, LOI_RT_DISPOSITION, false);
        for (LOI__c loi : lois) {
            loi.Disposition__c = dispositionId;
        }
        insertIf(doInsert, lois);
        return lois;
    }

    /** Single disposition-parented LOI. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The LOI. */
    public static LOI__c createDispositionLoi(Id dispositionId, Boolean doInsert) {
        return createDispositionLois(1, dispositionId, doInsert)[0];
    }

    /**
     * Resolves an LOI__c record type developer name to its Id, or null when it does not exist in
     * this org / is not available to the running user. An UNRECOGNISED name is a caller mistake
     * and throws, so a typo fails loudly instead of silently producing a default-record-type
     * fixture.
     *
     * 🔴 THE ALLOW-LIST COMPARISON MUST BE CASE-SENSITIVE, AND `!=` IS NOT — the identical trap
     * dispositionRecordTypeId documents at length. Apex `==` / `!=` on String is
     * case-INSENSITIVE while getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY,
     * so with `!=` a name like 'acquisition_loi' would pass the guard, miss the describe map, and
     * silently degrade to the platform default. `String.equals(Object)` is case-sensitive, so
     * guard and lookup answer the same question. Constant-first keeps a null argument on the
     * throw path rather than NPE-ing.
     */
    private static Id loiRecordTypeId(String recordTypeDeveloperName) {
        if (!LOI_RT_ACQUISITION.equals(recordTypeDeveloperName)
            && !LOI_RT_DISPOSITION.equals(recordTypeDeveloperName)) {
            throw new TestDataFactoryException(
                'Unknown LOI__c record type: ' + recordTypeDeveloperName
                + '. Expected Acquisition_LOI or Disposition_LOI.'
            );
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** LOIs under the shared scaffold Opportunity. @param count Number. @param doInsert Insert when true. @return LOIs. */
    public static List<LOI__c> createLois(Integer count, Boolean doInsert) {
        return createLois(count, defaultOpportunity().Id, doInsert);
    }

    /** Single LOI. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The LOI. */
    public static LOI__c createLoi(Id opportunityId, Boolean doInsert) {
        return createLois(1, opportunityId, doInsert)[0];
    }

    /**
     * Counter offers. Direction__c has no picklist default, so it is set.
     * @param count    Number of Counter Offers.
     * @param loiId    Parent LOI__c (required for a meaningful record).
     * @param doInsert Insert when true.
     * @return Counter Offers.
     */
    public static List<Counter_Offer__c> createCounterOffers(Integer count, Id loiId, Boolean doInsert) {
        requirePositive(count);
        requireId(loiId, 'loiId');
        List<Counter_Offer__c> counters = new List<Counter_Offer__c>();
        for (Integer i = 0; i < count; i++) {
            counters.add(new Counter_Offer__c(
                LOI__c = loiId,
                Direction__c = 'Seller',
                Counter_Price__c = 1050000 + (i * 1000),
                Counter_Cap_Rate__c = 6.25,
                Counter_Date__c = Date.today().addDays(i),
                Revision_Number__c = String.valueOf(i + 1) // TEXT despite the "_Number" suffix
            ));
        }
        insertIf(doInsert, counters);
        return counters;
    }

    /** Counter offers under the shared scaffold LOI. @param count Number. @param doInsert Insert when true. @return Counter Offers. */
    public static List<Counter_Offer__c> createCounterOffers(Integer count, Boolean doInsert) {
        return createCounterOffers(count, defaultLoi().Id, doInsert);
    }

    /** Single Counter Offer. @param loiId Parent LOI. @param doInsert Insert when true. @return The Counter Offer. */
    public static Counter_Offer__c createCounterOffer(Id loiId, Boolean doInsert) {
        return createCounterOffers(1, loiId, doInsert)[0];
    }

    /**
     * @param count         Number of Underwritings.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return Underwritings at stage 'Requested'.
     */
    public static List<Underwriting__c> createUnderwritings(Integer count, Id opportunityId, Boolean doInsert) {
        requirePositive(count);
        List<Underwriting__c> records = new List<Underwriting__c>();
        for (Integer i = 0; i < count; i++) {
            records.add(new Underwriting__c(
                Opportunity__c = opportunityId,
                Stage__c = 'Requested',
                Status__c = 'In Progress',
                My_Price__c = 1000000 + (i * 1000),
                My_Cap_Rate__c = 6.75,
                Market_Cap_Rate__c = 6.0,
                Underwritten_NOI__c = 65000 + (i * 100),
                Equity_Required__c = 300000,
                Projected_Loan__c = 700000,
                Hold_Period__c = 5,
                Target_Return__c = 15,
                Year_5_IRR__c = 16,
                Equity_Multiple__c = 1.8,
                Cash_On_Cash_Return__c = 8,
                GRM__c = 12
            ));
        }
        insertIf(doInsert, records);
        return records;
    }

    /** Underwritings under the shared scaffold Opportunity. @param count Number. @param doInsert Insert when true. @return Underwritings. */
    public static List<Underwriting__c> createUnderwritings(Integer count, Boolean doInsert) {
        return createUnderwritings(count, defaultOpportunity().Id, doInsert);
    }

    /** Single Underwriting. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The Underwriting. */
    public static Underwriting__c createUnderwriting(Id opportunityId, Boolean doInsert) {
        return createUnderwritings(1, opportunityId, doInsert)[0];
    }

    /** Contract_Review__c record type developer name for the buy-side PSA (the factory default). */
    public static final String CONTRACT_REVIEW_RT_ACQUISITION = 'Acquisition_PSA';
    /** Contract_Review__c record type developer name for the sell-side PSA. */
    public static final String CONTRACT_REVIEW_RT_DISPOSITION = 'Disposition_PSA';

    /**
     * Contract Reviews on the ACQUISITION record type — the shape OpportunityReviewService
     * auto-creates on entry to the PSA stage.
     *
     * @param count         Number of Contract Reviews.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return Contract Reviews at stage 'PSA Drafting', record type Acquisition_PSA.
     */
    public static List<Contract_Review__c> createContractReviews(Integer count, Id opportunityId, Boolean doInsert) {
        return createContractReviews(count, opportunityId, CONTRACT_REVIEW_RT_ACQUISITION, doInsert);
    }

    /**
     * Contract Reviews on an explicit record type (D16.3, Tranche 3C). Same shape and same
     * reasoning as createNdas / createLois / createDispositions — see createDispositions' header
     * for why the record type is stamped at all rather than inherited from the test-running user's
     * profile default.
     *
     * ═════════════════════════════════════════════════════════════════════════════════════
     * 🔴 REWRITTEN 2026-08-14 (Acquisition Observations phase 3, observation 7 / requirement C3).
     * THE SEED IS NOW CHOSEN BY RECORD TYPE, LIKE createNdas AND createLois. THE PARAGRAPH THIS
     * REPLACES SAID THE OPPOSITE AND WAS CORRECT WHEN WRITTEN — DO NOT RESTORE IT.
     * ═════════════════════════════════════════════════════════════════════════════════════
     *
     * RETRACTED, verbatim: "UNLIKE createNdas AND createLois, NOTHING ELSE IN THE ROW VARIES BY
     * RECORD TYPE... Both PSA record types expose the IDENTICAL four Negotiation_Status__c values
     * and the identical three Stage__c values — Disposition_PSA's own record type file states this
     * is deliberate — so one seed is correct for both and a branch here would be inventing a
     * difference that does not exist."
     *
     * Phase 3 made that difference REAL. Acquisition_PSA's sequence is now
     * `Draft -> Negotiation -> Signed -> Executed`; Disposition_PSA keeps
     * `Initial Draft -> Revised -> Ready for Execution -> Executed` (decision O3, a hard stop).
     * 'Executed' is the only shared value, and it is the terminal on both — so, exactly as on
     * LOI__c, there is no shared STARTING value and one seed cannot serve both.
     *
     * 🔴 THIS FIXES THE TEST-SIDE TWIN OF THE DEFECT `OpportunityReviewService`'s C3 FIX JUST
     * CLOSED IN PRODUCTION. This method seeded NO Negotiation_Status__c at all, so every fixture
     * fell to the FIELD-LEVEL default — 'Initial Draft' — while the method stamped Acquisition_PSA,
     * which after phase 3 does not carry that value.
     * ⚠ RETRACTED 2026-08-21 — THIS ONE IS A CLAIM ABOUT WHAT WAS OBSERVED, AND IT CANNOT HAVE
     * BEEN. It read: "Record-type picklist restriction is UI-ONLY and Apex DML does not enforce it,
     * so the row COMMITTED SILENTLY and produced a fixture whose status is off its own record
     * type's value set: `RecordStageAdvanceService` finds no entry for it in the acquisition map
     * and refuses the first Advance Stage click, for a reason no test message would explain."
     * `Negotiation_Status__c` is `restricted` and 'Initial Draft' on an Acquisition_PSA was MEASURED
     * being refused (RecordStageAdvanceService's class header). A silent commit was therefore not
     * possible; the unseeded fixture would have failed at the insert. Do NOT read the old sentence
     * as evidence of a real observation — it is a prediction from the false premise, written before
     * the measurement. The per-type seed is still required and this method still needs it.
     *
     * 🔴 DO NOT "FIX" THIS BY MOVING THE FIELD-LEVEL DEFAULT. It is 'Initial Draft' because
     * Disposition_PSA still runs on it (O3). Changing the default would relocate the identical
     * defect onto the sell-side path — the same trap `Contract_Review_Stage_Sync` records for its
     * own literal, where the rule was ADD a branch, never SWAP one.
     *
     * ⚠ THE ACQUISITION SEED MATCHES WHAT `OpportunityReviewService` NOW STAMPS ON THE ROWS IT
     * AUTO-CREATES (`ACQUISITION_PSA_STATUS = 'Draft'`), which is the point: a fixture that starts
     * somewhere production never starts is a fixture that tests a state that cannot occur.
     *
     * ⚠ AND THE SEED IS CORRECT EVEN WHEN THE RECORD-TYPE STAMP NO-OPS. The stamp is guarded on
     * isAvailable(), so before post-deploy gate T-A1 the row lands on Master — and the acquisition
     * FALLBACK map in RecordStageAdvanceService (`defaultTypeKey`) is the acquisition one, which has
     * an entry for 'Draft' and none for 'Initial Draft'. So the guarded-stamp degradation stays
     * WALKABLE rather than dead. Same argument OpportunityReviewService's header makes for the rows
     * it creates; the two are load-bearing together.
     *
     * ⚠ Ball_In_Court__c IS DELIBERATELY LEFT UNSET on both types, even though it is the ONE field
     * whose value set genuinely differs ('Seller' on Acquisition_PSA, 'Buyer' on Disposition_PSA —
     * the inversion those record types exist to fix). Two reasons: this factory has never seeded
     * it, so seeding it now would silently change the starting state of every existing Contract
     * Review fixture in the repo; and nothing DERIVES from a seeded value — PsaVersionService
     * WRITES the field, so a fixture that pre-populates it can only mask a bug in that write. A
     * test that needs a starting ball-in-court should set it explicitly and say why.
     *
     * ⚠ The stamp is GUARDED on isAvailable(), exactly like createNdas / createLois /
     * createDispositions: an undeployed or unassigned record type leaves RecordTypeId unset rather
     * than turning every Contract Review test in the repo red. A green suite is therefore NOT proof
     * the record types landed — TestDataFactoryTest and post-deploy gate T-A1 are.
     *
     * @param count                   Number of Contract Reviews.
     * @param opportunityId           Parent Opportunity (nullable).
     * @param recordTypeDeveloperName CONTRACT_REVIEW_RT_ACQUISITION or CONTRACT_REVIEW_RT_DISPOSITION.
     * @param doInsert                Insert when true.
     * @return Contract Reviews seeded at their record type's STARTING Negotiation_Status__c,
     *         Stage__c 'PSA Drafting'.
     */
    public static List<Contract_Review__c> createContractReviews(
        Integer count,
        Id opportunityId,
        String recordTypeDeveloperName,
        Boolean doInsert
    ) {
        requirePositive(count);
        Id recordTypeId = contractReviewRecordTypeId(recordTypeDeveloperName);
        // Constant-first String.equals, not `==`: Apex `==` on String is case-INSENSITIVE while the
        // describe map this name is also fed to is case-SENSITIVE. Same note as loiRecordTypeId's.
        Boolean isDisposition = CONTRACT_REVIEW_RT_DISPOSITION.equals(recordTypeDeveloperName);
        List<Contract_Review__c> reviews = new List<Contract_Review__c>();
        for (Integer i = 0; i < count; i++) {
            Contract_Review__c cr = new Contract_Review__c(
                Opportunity__c = opportunityId,
                // 🔴 SEEDED EXPLICITLY, PER RECORD TYPE — see this method's header. Leaving it to the
                // field-level default ('Initial Draft') aimed every ACQUISITION fixture at a value
                // that record type no longer carries. ⚠ 2026-08-21: this comment used to end
                // "silently, because Apex DML does not enforce record-type picklist restriction" —
                // false for this restricted field; the insert is refused. See the method header.
                Negotiation_Status__c = isDisposition ? 'Initial Draft' : 'Draft',
                // ⚠ Stage__c is a DERIVED PROJECTION — Contract_Review_Stage_Sync recomputes it from
                // Negotiation_Status__c on every save, so this seed is replaced on insert by the
                // flow's mapping of the status above. It is kept because removing it changes nothing
                // and would read like a fix. Both seeds project to 'PSA Drafting' (the flow's
                // Is_Draft and Is_Initial_Draft rules both connect to Set_Stage_Drafting), so this
                // value stays correct on both sides of the branch.
                Stage__c = 'PSA Drafting',
                Contract_Value__c = 1000000 + (i * 1000),
                PSA_Date__c = Date.today()
            );
            if (recordTypeId != null) {
                cr.RecordTypeId = recordTypeId;
            }
            reviews.add(cr);
        }
        insertIf(doInsert, reviews);
        return reviews;
    }

    /**
     * Contract Reviews parented to a DISPOSITION, on the Disposition_PSA record type — the
     * sell-side PSA whose execution ContractExecutionService turns into a `Closing` stage advance.
     *
     * ⚠ Opportunity__c is left NULL deliberately, and here that is load-bearing rather than merely
     * tidy: `ContractExecutionService.handleExecution` runs its two arms off the two parent
     * LOOKUPS, not off the record type, so a fixture carrying BOTH parents would run BOTH arms and
     * make the acquisition and disposition assertions indistinguishable.
     *
     * @param count         Number of Contract Reviews.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Contract Reviews at stage 'PSA Drafting', record type Disposition_PSA.
     */
    public static List<Contract_Review__c> createDispositionContractReviews(
        Integer count,
        Id dispositionId,
        Boolean doInsert
    ) {
        List<Contract_Review__c> reviews =
            createContractReviews(count, null, CONTRACT_REVIEW_RT_DISPOSITION, false);
        for (Contract_Review__c cr : reviews) {
            cr.Disposition__c = dispositionId;
        }
        insertIf(doInsert, reviews);
        return reviews;
    }

    /** Single disposition-parented Contract Review. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The Contract Review. */
    public static Contract_Review__c createDispositionContractReview(Id dispositionId, Boolean doInsert) {
        return createDispositionContractReviews(1, dispositionId, doInsert)[0];
    }

    /**
     * Resolves a Contract_Review__c record type developer name to its Id, or null when it does not
     * exist in this org / is not available to the running user. An UNRECOGNISED name is a caller
     * mistake and throws, so a typo fails loudly instead of silently producing a
     * default-record-type fixture.
     *
     * 🔴 THE ALLOW-LIST COMPARISON MUST BE CASE-SENSITIVE, AND `!=` IS NOT — the identical trap
     * dispositionRecordTypeId documents at length. Apex `==` / `!=` on String is case-INSENSITIVE
     * while getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY, so with `!=` a name
     * like 'acquisition_psa' would pass the guard, miss the describe map, and silently degrade to
     * the platform default. `String.equals(Object)` is case-sensitive, so guard and lookup answer
     * the same question. Constant-first keeps a null argument on the throw path rather than
     * NPE-ing.
     *
     * ⚠ THE GUARD MATTERS MORE HERE THAN ON THE TWO SIBLINGS, BUT THE REASON CHANGED ON 2026-08-14
     * AND IS NOW STRONGER, NOT WEAKER. RETRACTED, verbatim: "THE SILENT DEGRADATION WOULD BE HARDER
     * TO SPOT ON THIS OBJECT THAN ON ITS TWO SIBLINGS ... a mis-typed PSA record type produces a
     * fixture that walks PERFECTLY (both types share one sequence) and is wrong only about which
     * PERSONA may drive it." Observation 7 split the sequences, so both types no longer share one,
     * and createContractReviews now seeds per type. A name that slipped past this guard would
     * therefore degrade to the platform default record type WHILE TAKING THE ACQUISITION SEED — a
     * row whose status and record type disagree. ⚠ 2026-08-21: this used to continue "inserted
     * silently because Apex DML does not enforce record-type picklist restriction, and refused by
     * RecordStageAdvanceService on its first advance for a reason no test message would explain" —
     * false for this restricted field. The disagreeing row is refused AT THE INSERT, so the guard's
     * value is that it names the typo instead of letting a platform error code stand in for it.
     * That is a smaller claim than the old one and it is the true one. A mis-typed NDA or LOI record type still
     * produces a fixture whose stage is off its own value set and whose walk test fails.
     * TestDataFactoryTest.createContractReviews_caseTypoRecordTypeName_throwsAndNamesTheOffendingValue
     * carries this same argument.
     */
    private static Id contractReviewRecordTypeId(String recordTypeDeveloperName) {
        if (!CONTRACT_REVIEW_RT_ACQUISITION.equals(recordTypeDeveloperName)
            && !CONTRACT_REVIEW_RT_DISPOSITION.equals(recordTypeDeveloperName)) {
            throw new TestDataFactoryException(
                'Unknown Contract_Review__c record type: ' + recordTypeDeveloperName
                + '. Expected Acquisition_PSA or Disposition_PSA.'
            );
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** Contract Reviews under the shared scaffold Opportunity. @param count Number. @param doInsert Insert when true. @return Contract Reviews. */
    public static List<Contract_Review__c> createContractReviews(Integer count, Boolean doInsert) {
        return createContractReviews(count, defaultOpportunity().Id, doInsert);
    }

    /** Single Contract Review. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The Contract Review. */
    public static Contract_Review__c createContractReview(Id opportunityId, Boolean doInsert) {
        return createContractReviews(1, opportunityId, doInsert)[0];
    }

    /**
     * PSA versions. Contract_Review__c is a REQUIRED lookup (deleteConstraint
     * Restrict). Direction__c has no picklist default, so it is set.
     * @param count            Number of PSA Versions.
     * @param contractReviewId Parent Contract_Review__c (required).
     * @param doInsert         Insert when true.
     * @return PSA Versions.
     */
    public static List<PSA_Version__c> createPsaVersions(Integer count, Id contractReviewId, Boolean doInsert) {
        requirePositive(count);
        requireId(contractReviewId, 'contractReviewId (PSA_Version__c.Contract_Review__c is required)');
        List<PSA_Version__c> versions = new List<PSA_Version__c>();
        for (Integer i = 0; i < count; i++) {
            versions.add(new PSA_Version__c(
                Contract_Review__c = contractReviewId,
                Direction__c = 'Ours',
                Version_Date__c = Date.today().addDays(i),
                Summary__c = 'Test PSA version ' + i,
                Document_URL__c = 'https://example.invalid/psa/' + i
            ));
        }
        insertIf(doInsert, versions);
        return versions;
    }

    /** PSA versions under the shared scaffold Contract Review. @param count Number. @param doInsert Insert when true. @return PSA Versions. */
    public static List<PSA_Version__c> createPsaVersions(Integer count, Boolean doInsert) {
        return createPsaVersions(count, defaultContractReview().Id, doInsert);
    }

    /** Single PSA Version. @param contractReviewId Parent Contract Review. @param doInsert Insert when true. @return The PSA Version. */
    public static PSA_Version__c createPsaVersion(Id contractReviewId, Boolean doInsert) {
        return createPsaVersions(1, contractReviewId, doInsert)[0];
    }

    /**
     * Deal messages parented to an LOI. The active Exactly_One_Parent validation
     * rule requires EXACTLY one of LOI / Underwriting / Contract Review — hence
     * three distinct methods rather than one with nullable parents.
     * @param count    Number of Deal Messages.
     * @param loiId    Parent LOI__c (required).
     * @param doInsert Insert when true.
     * @return Deal Messages.
     */
    public static List<Deal_Message__c> createDealMessagesForLoi(Integer count, Id loiId, Boolean doInsert) {
        requireId(loiId, 'loiId');
        List<Deal_Message__c> messages = buildDealMessages(count);
        for (Deal_Message__c message : messages) {
            message.LOI__c = loiId;
        }
        insertIf(doInsert, messages);
        return messages;
    }

    /**
     * Deal messages parented to an Underwriting (exactly-one-parent rule).
     * @param count          Number of Deal Messages.
     * @param underwritingId Parent Underwriting__c (required).
     * @param doInsert       Insert when true.
     * @return Deal Messages.
     */
    public static List<Deal_Message__c> createDealMessagesForUnderwriting(
        Integer count,
        Id underwritingId,
        Boolean doInsert
    ) {
        requireId(underwritingId, 'underwritingId');
        List<Deal_Message__c> messages = buildDealMessages(count);
        for (Deal_Message__c message : messages) {
            message.Underwriting__c = underwritingId;
        }
        insertIf(doInsert, messages);
        return messages;
    }

    /**
     * Deal messages parented to a Contract Review (exactly-one-parent rule).
     * @param count            Number of Deal Messages.
     * @param contractReviewId Parent Contract_Review__c (required).
     * @param doInsert         Insert when true.
     * @return Deal Messages.
     */
    public static List<Deal_Message__c> createDealMessagesForContractReview(
        Integer count,
        Id contractReviewId,
        Boolean doInsert
    ) {
        requireId(contractReviewId, 'contractReviewId');
        List<Deal_Message__c> messages = buildDealMessages(count);
        for (Deal_Message__c message : messages) {
            message.Contract_Review__c = contractReviewId;
        }
        insertIf(doInsert, messages);
        return messages;
    }

    private static List<Deal_Message__c> buildDealMessages(Integer count) {
        requirePositive(count);
        Datetime entryStamp = System.now();
        List<Deal_Message__c> messages = new List<Deal_Message__c>();
        for (Integer i = 0; i < count; i++) {
            messages.add(new Deal_Message__c(
                Direction__c = 'Internal',
                Method__c = 'Note',
                Entry_DateTime__c = entryStamp, // ARCHITECTURE.md §1 rule-9 stamp
                Details__c = 'Test deal message ' + i,
                Revision__c = String.valueOf(i + 1) // TEXT, not Number
            ));
        }
        return messages;
    }

    /**
     * @param count         Number of Development Feasibility Reviews.
     * @param opportunityId Parent Opportunity (nullable).
     * @param propertyId    Parent Property__c (nullable).
     * @param doInsert      Insert when true.
     * @return Reviews at stage 'Requested'.
     */
    public static List<Development_Feasibility_Review__c> createDevelopmentReviews(
        Integer count,
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Development_Feasibility_Review__c> reviews = new List<Development_Feasibility_Review__c>();
        for (Integer i = 0; i < count; i++) {
            reviews.add(new Development_Feasibility_Review__c(
                Opportunity__c = opportunityId,
                Property__c = propertyId,
                Requested_By__c = UserInfo.getUserId(),
                Stage__c = 'Requested',
                Architecture_Firm__c = 'Test Architects ' + i,
                Developable_Area__c = 5000 + (i * 10),
                Proposals_Target__c = '3',        // TEXT, not Number
                Proposals_Received__c = 0,
                Est_Cost_Impact__c = '100000'     // TEXT, not Currency
            ));
        }
        insertIf(doInsert, reviews);
        return reviews;
    }

    /** Single Development Feasibility Review. @param opportunityId Parent Opp. @param propertyId Parent Property. @param doInsert Insert when true. @return The review. */
    public static Development_Feasibility_Review__c createDevelopmentReview(
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        return createDevelopmentReviews(1, opportunityId, propertyId, doInsert)[0];
    }

    /**
     * @param count         Number of Construction Feasibility Reviews.
     * @param opportunityId Parent Opportunity (nullable).
     * @param propertyId    Parent Property__c (nullable).
     * @param doInsert      Insert when true.
     * @return Reviews at stage 'Requested'.
     */
    public static List<Construction_Feasibility_Review__c> createConstructionReviews(
        Integer count,
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Construction_Feasibility_Review__c> reviews = new List<Construction_Feasibility_Review__c>();
        for (Integer i = 0; i < count; i++) {
            reviews.add(new Construction_Feasibility_Review__c(
                Opportunity__c = opportunityId,
                Property__c = propertyId,
                Requested_By__c = UserInfo.getUserId(),
                Stage__c = 'Requested',
                Roof_Age_Years__c = 10,
                Estimated_Roof_Cost__c = 50000,
                Estimated_MEP_Cost__c = 25000,
                Estimated_Upgrade_Cost__c = 75000,
                Estimated_Timeline_Impact__c = '30', // TEXT, not Number
                Addition_Work_Required__c = false
            ));
        }
        insertIf(doInsert, reviews);
        return reviews;
    }

    /** Single Construction Feasibility Review. @param opportunityId Parent Opp. @param propertyId Parent Property. @param doInsert Insert when true. @return The review. */
    public static Construction_Feasibility_Review__c createConstructionReview(
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        return createConstructionReviews(1, opportunityId, propertyId, doInsert)[0];
    }

    /**
     * @param count         Number of Offerings.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return Offerings at status 'Draft'.
     */
    public static List<Offering__c> createOfferings(Integer count, Id opportunityId, Boolean doInsert) {
        requirePositive(count);
        List<Offering__c> offerings = new List<Offering__c>();
        for (Integer i = 0; i < count; i++) {
            offerings.add(new Offering__c(
                Opportunity__c = opportunityId,
                IR_Owner__c = UserInfo.getUserId(),
                Status__c = 'Draft'
            ));
        }
        insertIf(doInsert, offerings);
        return offerings;
    }

    /** Single Offering. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The Offering. */
    public static Offering__c createOffering(Id opportunityId, Boolean doInsert) {
        return createOfferings(1, opportunityId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANSACTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count         Number of Transactions.
     * @param opportunityId Parent Opportunity (nullable).
     * @param propertyId    Parent Property__c (nullable).
     * @param doInsert      Insert when true.
     * @return Transactions at stage 'Open Contract'.
     */
    public static List<Transaction__c> createTransactions(
        Integer count,
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Transaction__c> transactions = new List<Transaction__c>();
        for (Integer i = 0; i < count; i++) {
            transactions.add(new Transaction__c(
                Opportunity__c = opportunityId,
                Property__c = propertyId,
                Stage__c = 'Open Contract',
                Status__c = 'Active',
                Contract_Value__c = 1000000 + (i * 1000),
                Earnest_Money__c = 50000,
                Loan_Required__c = false,
                Contract_Executed_Date__c = Date.today(),
                Feasibility_Deadline__c = Date.today().addDays(45),
                Target_Close_Date__c = Date.today().addDays(75),
                // Is_Wire_Approval_Due__c is a CHECKBOX despite the date-sounding name.
                Is_Wire_Approval_Due__c = false
            ));
        }
        insertIf(doInsert, transactions);
        return transactions;
    }

    /** Standalone Transactions (no parents). @param count Number. @param doInsert Insert when true. @return Transactions. */
    public static List<Transaction__c> createTransactions(Integer count, Boolean doInsert) {
        return createTransactions(count, null, null, doInsert);
    }

    /** Single Transaction. @param opportunityId Parent Opp. @param propertyId Parent Property. @param doInsert Insert when true. @return The Transaction. */
    public static Transaction__c createTransaction(Id opportunityId, Id propertyId, Boolean doInsert) {
        return createTransactions(1, opportunityId, propertyId, doInsert)[0];
    }

    /**
     * Critical dates. BOTH Transaction__c and Due_Date__c are schema-required.
     * Type__c has no picklist default, so it is set.
     * @param count         Number of Critical Dates.
     * @param transactionId Parent Transaction__c (required).
     * @param doInsert      Insert when true.
     * @return Critical Dates.
     */
    public static List<Critical_Date__c> createCriticalDates(Integer count, Id transactionId, Boolean doInsert) {
        requirePositive(count);
        requireId(transactionId, 'transactionId (Critical_Date__c.Transaction__c is required)');
        List<Critical_Date__c> dates = new List<Critical_Date__c>();
        for (Integer i = 0; i < count; i++) {
            dates.add(new Critical_Date__c(
                Transaction__c = transactionId,
                Type__c = 'Closing Date',
                Due_Date__c = Date.today().addDays(30 + i)
            ));
        }
        insertIf(doInsert, dates);
        return dates;
    }

    /** Critical dates under the shared scaffold Transaction. @param count Number. @param doInsert Insert when true. @return Critical Dates. */
    public static List<Critical_Date__c> createCriticalDates(Integer count, Boolean doInsert) {
        return createCriticalDates(count, defaultTransaction().Id, doInsert);
    }

    /** Single Critical Date. @param transactionId Parent Transaction. @param doInsert Insert when true. @return The Critical Date. */
    public static Critical_Date__c createCriticalDate(Id transactionId, Boolean doInsert) {
        return createCriticalDates(1, transactionId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHECKLISTS (Checklist__c -> Checklist_Item__c, both master-detail)
    //
    // ⚠ NEITHER OBJECT HAS AN OwnerId. Both are ControlledByParent detail records, so
    // "owner" is Owner_Label__c, a ROLE STRING (Danish / CFO / Legal / FES /
    // Accounting / Prop. Mgmt.), never a User. Do not try to set an owner here.
    // ⚠ Checklist_Item__c.Blocked_By__c is a REAL self-lookup, so it cannot be set in
    // the same statement that creates its target. createChecklistItems leaves it null;
    // link() below is the second pass, mirroring what ChecklistFanoutService does.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Checklist groups under a Transaction.
     *
     * @param count         Number of groups (letters are generated A, B, C ...).
     * @param transactionId Master-detail parent (required — a detail record cannot be
     *                      created without one).
     * @param doInsert      Insert when true.
     * @return Checklists, sequenced from 1.
     */
    public static List<Checklist__c> createChecklists(
        Integer count,
        Id transactionId,
        Boolean doInsert
    ) {
        requirePositive(count);
        requireId(transactionId, 'transactionId (Checklist__c.Transaction__c is master-detail)');
        final List<String> letters = new List<String>{
            'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'
        };
        List<Checklist__c> checklists = new List<Checklist__c>();
        for (Integer i = 0; i < count; i++) {
            String letter = i < letters.size() ? letters[i] : 'X' + i;
            checklists.add(new Checklist__c(
                Transaction__c = transactionId,
                Group_Letter__c = letter,
                Group_Name__c = 'Test Group ' + letter,
                Owner_Label__c = 'Danish',
                Sequence__c = i + 1,
                // Byte-identical to the first value of Transaction__c.Stage__c. The picklist is
                // RESTRICTED and restricted picklists ARE enforced by DML on this project.
                Stage__c = 'Open Contract',
                Is_Conditional__c = false
            ));
        }
        insertIf(doInsert, checklists);
        return checklists;
    }

    /** Single Checklist. @param transactionId Parent deal. @param doInsert Insert when true. @return The Checklist. */
    public static Checklist__c createChecklist(Id transactionId, Boolean doInsert) {
        return createChecklists(1, transactionId, doInsert)[0];
    }

    /**
     * Checklist items under one checklist group.
     *
     * Flag__c is set explicitly to 'None' rather than relying on the picklist default, so a test
     * that asserts a transition is never comparing against an unset value.
     *
     * @param count       Number of items.
     * @param checklistId Master-detail parent (required).
     * @param doInsert    Insert when true.
     * @return Items, sequenced from 1, all open and none critical.
     */
    public static List<Checklist_Item__c> createChecklistItems(
        Integer count,
        Id checklistId,
        Boolean doInsert
    ) {
        requirePositive(count);
        requireId(checklistId, 'checklistId (Checklist_Item__c.Checklist__c is master-detail)');
        List<Checklist_Item__c> items = new List<Checklist_Item__c>();
        for (Integer i = 0; i < count; i++) {
            items.add(new Checklist_Item__c(
                Checklist__c = checklistId,
                Subject__c = 'Test Checklist Item ' + i,
                Sequence__c = i + 1,
                Flag__c = 'None',
                Stage__c = 'Open Contract',
                Owner_Label__c = 'Danish',
                Is_Critical__c = false,
                Is_Wire_Verification__c = false,
                Is_Conditional__c = false,
                Due_Date__c = Date.today().addDays(14)
            ));
        }
        insertIf(doInsert, items);
        return items;
    }

    /** Single Checklist Item. @param checklistId Parent group. @param doInsert Insert when true. @return The item. */
    public static Checklist_Item__c createChecklistItem(Id checklistId, Boolean doInsert) {
        return createChecklistItems(1, checklistId, doInsert)[0];
    }

    /**
     * The prerequisite second pass: points one INSERTED item at another.
     *
     * Exists because `Blocked_By__c` is a real lookup and therefore cannot be populated in the same
     * statement that creates its target — the same reason `ChecklistFanoutService` needs a second
     * DML pass. A test that tries to do it in one statement gets a null lookup and silently proves
     * nothing.
     *
     * @param dependent    The item to block (must be inserted).
     * @param prerequisite The item it must wait for (must be inserted).
     * @param doUpdate     Update when true.
     * @return The dependent, with Blocked_By__c set and Is_Prerequisite_Met__c false.
     */
    public static Checklist_Item__c linkPrerequisite(
        Checklist_Item__c dependent,
        Checklist_Item__c prerequisite,
        Boolean doUpdate
    ) {
        requireId(dependent == null ? null : dependent.Id, 'dependent.Id');
        requireId(prerequisite == null ? null : prerequisite.Id, 'prerequisite.Id');
        Checklist_Item__c link = new Checklist_Item__c(
            Id = dependent.Id,
            Blocked_By__c = prerequisite.Id,
            Is_Prerequisite_Met__c = false
        );
        if (doUpdate == true) {
            update link;
        }
        return link;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DISPOSITIONS
    // ⚠ CORRECTED 2026-08-31 (Phase 1 of the Transaction checklist rewrite). This block
    // and createWires below BOTH used to assert "the org has no Wire__c -> Transaction__c
    // relationship". THAT IS NO LONGER TRUE: Wire__c.Transaction__c ships in the Phase 1
    // schema (objects/Wire__c/fields/Transaction__c.field-meta.xml), alongside
    // Wire__c.Wire_Type__c. The factory still parents test Wires to Disposition__c
    // because that is the only wired path today; a Transaction-parented Wire is a
    // Phase 5 fixture and should be added as its own overload rather than by
    // repointing this one.
    // ⚠ Transaction__c.Wire_Open_Risks__c is still NOT computed from Wire__c. On the
    // legacy model it is a subject-string parse over checklist Tasks; on the new model
    // it is a count of Checklist_Item__c.Is_Wire_Verification__c. Neither reads Wire__c.
    // ═══════════════════════════════════════════════════════════════════════════

    // 🔴 THESE TWO LITERALS ARE THE ONE SANCTIONED EXCEPTION TO DispositionDomain's "every other
    // class derives from here" rule, and that exemption is recorded in DispositionDomain's own
    // header. DO NOT repoint them at DispositionDomain.RT_ON_MARKET / RT_OFF_MARKET. Every other
    // holder of this pair is an alias of that class, so a mis-casing there would flow into the
    // fixtures AND the assertions together and the suite would stay green against a describe map
    // that matched nothing. This independent copy is what makes
    // TestDataFactoryTest.createDisposition_caseTypoRecordTypeName_throwsAndNamesTheOffendingValue
    // a falsifier instead of a tautology. If the pairs ever disagree, the test is working.

    /** Disposition__c record type developer name for the broker-listed path (the factory default). */
    public static final String DISPOSITION_RT_ON_MARKET = 'On_Market';
    /** Disposition__c record type developer name for the direct-sale path. */
    public static final String DISPOSITION_RT_OFF_MARKET = 'Off_Market';

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE NON-OWNER APPROVER PERSONA. ADDED 2026-08-21 FOR THE `DISP-0011` SHARING DEFECT.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * A user who can SEE every Disposition and OWN none of them — the exact principal whose parent
     * write was silently refused in production while every disposition test in this repo stayed
     * green. Those tests ran as the admin test-running user, who OWNS every fixture record they
     * insert, so record-level sharing was never consulted and the defect was unreachable by
     * construction. **A test that cannot fail on a defect is not a test of it**; this fixture is
     * what makes it reachable.
     *
     * ── 🔴 WHY `Minimum Access - Salesforce` AND NOT `Standard User` ─────────────────────────
     * `.claude/rules` and this repo's own history (`denial-tests-need-minimum-access-profile`):
     * `Standard User` carries broad standard-object grants that mask a denial and make a permission
     * test pass for the wrong reason. Everything this persona can do must come from an assigned
     * permission set that a real DPEG principal also holds — nothing from the base profile.
     *
     * ── 🔴 WHY `DPEG_Disposition_Edit` AND NOT THE REAL APPROVER'S `DPEG_Disposition_View` ────
     * MEASURED, NOT CHOSEN: a first version of this fixture assigned `DPEG_Disposition_View` — the
     * set the live Principal approver actually holds — and all five tests built on it failed with
     * `System.TypeException: DML operation UPDATE not allowed on Disposition_Offer__c` before ever
     * reaching the code under test. **Apex DML enforces OBJECT-level access even in a test's own
     * system-context DML**: an object the running user has NO Update permission on throws
     * `TypeException` regardless of `AccessLevel`, which is a harder stop than FLS and is not
     * bypassable (`TaskFanoutService`'s header records the same mechanism in production). The
     * persona has to be able to save the CHILD record in order for its trigger to run at all.
     *
     * ⚠ SO THIS PERSONA IS DELIBERATELY GIVEN **MORE** ACCESS THAN THE REAL APPROVER, AND THAT
     * MAKES THE TEST STRONGER RATHER THAN WEAKER. `DPEG_Disposition_Edit` carries
     * `allowEdit = true` AND `viewAllRecords = true` AND — decisively — `modifyAllRecords = false`
     * on `Disposition__c`, `Disposition_Offer__c` and `BOV_Submission__c`. Object-level CRUD is
     * therefore satisfied, so `AccessLevel.SYSTEM_MODE` has nothing left to contribute, and the
     * ONLY thing that can still refuse the parent write is RECORD-LEVEL SHARING. That is exactly
     * the dimension the 2026-08-21 fix addresses, isolated. A test that passes here can only be
     * passing because of the `without sharing` escape.
     *
     * ⚠ `DPEG_Acquisition_Edit` IS ADDED FOR ONE CALLER ONLY — `ContractExecutionServiceTest`, whose
     * trigger entry point is a `Contract_Review__c` save. NO disposition set grants edit on that
     * object (`DPEG_Disposition_Edit` gives it `allowEdit = false`); `DPEG_Acquisition_Edit` is the
     * only set that does. It grants `viewAllRecords` on Contract_Review__c and Opportunity but adds
     * NO `modifyAllRecords` anywhere, so it cannot rescue the Disposition write either.
     *
     * ⚠ THE GROUP `DPEG_Principal_PSG` IS DELIBERATELY NOT ASSIGNED INSTEAD. A `PermissionSetGroup`
     * must be in `Updated` status before it can be assigned, and recalculation is asynchronous and
     * org-state-dependent — a fixture that fails intermittently for a reason unrelated to the thing
     * under test is worse than one that is deliberately, documentedly over-provisioned.
     *
     * ⚠ MIXED_DML. `User` and `PermissionSetAssignment` are SETUP objects and callers always have
     * non-setup fixture DML in the same transaction, so both inserts run inside
     * `System.runAs(currentUser)` — the workaround used throughout this suite.
     *
     * ⚠ THIS USER HAS NO ROLE, DELIBERATELY. A role would expose the fixture to "Grant Access Using
     * Hierarchies" and to `Disposition_Team_RW` (Acquisitions_Analyst + subordinates ->
     * `DPEG_Acquisitions_Team`), either of which could hand the persona record-level edit and turn
     * the test green for a reason that has nothing to do with the code under test. The
     * `UserRecordAccess` precondition each caller asserts is what detects that if it ever happens.
     *
     * @param aliasSeed 1-4 lowercase characters identifying the calling test, so a failure names
     *                  which fixture produced the user. Required.
     * @return The inserted User. Callers must assert `UserRecordAccess` themselves — see
     *         `DispositionOfferTriggerHandlerTest.assertReadableButNotEditable` for the precondition
     *         assertions that keep this fixture honest.
     * @example
     * User approver = TestDataFactory.createNonOwnerDispositionApprover('doth');
     * System.runAs(approver) { update new Disposition_Offer__c(Id = o.Id, Approval_Status__c = 'Approved'); }
     */
    public static User createNonOwnerDispositionApprover(String aliasSeed) {
        if (String.isBlank(aliasSeed)) {
            throw new TestDataFactoryException('aliasSeed is required and cannot be blank.');
        }
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        List<PermissionSet> sets = [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN ('DPEG_Base_Access', 'DPEG_Disposition_Edit', 'DPEG_Acquisition_Edit')
        ];
        if (sets.size() != 3) {
            throw new TestDataFactoryException(
                'FIXTURE PRECONDITION FAILED: expected DPEG_Base_Access, DPEG_Disposition_Edit and '
                + 'DPEG_Acquisition_Edit to exist in this org; found ' + sets.size()
                + '. Without them this persona cannot save the child record whose trigger is under '
                + 'test, and every test built on it fails with System.TypeException before '
                + 'reaching the code. Deploy the permission sets first.');
        }
        String unique = aliasSeed + String.valueOf(DateTime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User approver = new User(
            FirstName = 'NonOwner',
            LastName = 'Approver',
            Alias = aliasSeed,
            Email = 'dpeg.approver@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert approver;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : sets) {
                assignments.add(new PermissionSetAssignment(
                    AssigneeId = approver.Id,
                    PermissionSetId = ps.Id
                ));
            }
            insert assignments;
        }
        return approver;
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE LOI SUBMITTER WHO CANNOT SEE THE NDA. ADDED 2026-08-30 FOR THE SIGNED-NDA GATE.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * A user who can see EVERY Opportunity, owns NONE of them, and has **no access whatsoever to
     * `NDA__c`** — no object permission, no `viewAllRecords`, and no ownership. Modelled on
     * `DPEG_Opportunity_View`, the Transactions team's Opportunity subset, which grants
     * `Opportunity` read + viewAllRecords and — verified in the file, 2026-08-30 — exactly ONE
     * NDA-related line in the entire set: `Opportunity.Primary_NDA__c` FLS. There is no
     * `objectPermissions` block for `NDA__c` at all.
     *
     * ── 🔴 WHY THIS FIXTURE HAD TO EXIST ────────────────────────────────────────────────────
     * `OpportunityApprovalService`'s signed-NDA gate reads `Primary_NDA__r.NDA_Signed__c` through
     * `OpportunitySelector.selectNdaGateById`, which is `WITH SYSTEM_MODE`. SYSTEM_MODE lifts
     * CRUD/FLS and **NEVER sharing**, and `NDA__c` OWD is `Private` (verified in
     * objects/NDA__c/NDA__c.object-meta.xml). If the spanning read were sharing-filtered on the
     * PARENT, a submitter who cannot see the NDA would get a null parent and the gate would REFUSE
     * a deal whose NDA IS signed — the gate INVERTING into a false block rather than degrading.
     *
     * Every gate test written before this fixture ran as the admin test-running user, who OWNS both
     * the Opportunity and the trigger-created NDA. Owner == submitter in 5 of 5, so record-level
     * sharing was never consulted and the defect was unreachable by construction — the exact shape
     * of this repo's recorded SYSTEM_MODE-does-not-lift-sharing production incident. **A test that
     * cannot fail on a defect is not a test of it.**
     *
     * ── 🔴 WHY `Minimum Access - Salesforce` AND NOT `Standard User` ──────────────────────────
     * Per `.claude/rules` and `denial-tests-need-minimum-access-profile`: `Standard User` carries
     * broad standard-object grants that mask a denial and make the test pass for the wrong reason.
     * Everything this persona can do must come from an assigned permission set a real DPEG
     * principal also holds.
     *
     * ⚠ THIS USER HAS NO ROLE, DELIBERATELY — a role would expose the fixture to "Grant Access
     * Using Hierarchies" and could hand it read on the NDA for a reason unrelated to the code under
     * test. The `UserRecordAccess` precondition the caller asserts is what detects that if it ever
     * changes.
     *
     * ⚠ MIXED_DML. `User` and `PermissionSetAssignment` are SETUP objects and callers always have
     * non-setup fixture DML in the same transaction, so both inserts run inside
     * `System.runAs(currentUser)` — the workaround used throughout this suite.
     *
     * @param aliasSeed 1-4 lowercase characters identifying the calling test, so a failure names
     *                  which fixture produced the user. Required.
     * @return The inserted User. 🔴 THE CALLER MUST ASSERT `UserRecordAccess` ITSELF — a plain SOQL
     *         probe inside `System.runAs` proves nothing here, because an Apex test class carries no
     *         sharing keyword and therefore runs `without sharing`.
     * @example
     * User submitter = TestDataFactory.createNonOwnerLoiSubmitter('nasl');
     */
    public static User createNonOwnerLoiSubmitter(String aliasSeed) {
        if (String.isBlank(aliasSeed)) {
            throw new TestDataFactoryException('aliasSeed is required and cannot be blank.');
        }
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        List<PermissionSet> sets = [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN ('DPEG_Base_Access', 'DPEG_Opportunity_View')
        ];
        if (sets.size() != 2) {
            throw new TestDataFactoryException(
                'FIXTURE PRECONDITION FAILED: expected DPEG_Base_Access and DPEG_Opportunity_View '
                + 'to exist in this org; found ' + sets.size() + '. Deploy the permission sets '
                + 'first — without them this persona cannot read an Opportunity at all and every '
                + 'test built on it fails for a reason that is not the code under test.');
        }
        String unique = aliasSeed + String.valueOf(DateTime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User submitter = new User(
            FirstName = 'NonOwner',
            LastName = 'Submitter',
            Alias = aliasSeed,
            Email = 'dpeg.submitter@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert submitter;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : sets) {
                assignments.add(new PermissionSetAssignment(
                    AssigneeId = submitter.Id,
                    PermissionSetId = ps.Id
                ));
            }
            insert assignments;
        }
        return submitter;
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE RECORD-TYPE-BLIND PRINCIPAL. ADDED 2026-08-25 FOR THE `DISP-0025` STAMP DEFECT.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * A user for whom `LOI__c.Disposition_LOI`, `NDA__c.Disposition_NDA` and
     * `Contract_Review__c.Disposition_PSA` are all `isAvailable() == false`, while the objects
     * themselves are readable. That is the exact principal whose approval was rolled back in
     * production on 2026-08-25 (DISP-0025 / OFFER-0012, approver Nikhil Dhanani, FINEST log
     * 07Liw000000I1vJEAS): the record-type stamp in `DispositionStageEntryService` silently
     * no-opped, the LOI landed on the acquisition default type, and the insert threw
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST on 'Received'.
     *
     * ── 🔴 WHY NOT `createNonOwnerDispositionApprover`, THE PERSONA THAT ALREADY EXISTS ──────
     * Because it holds `DPEG_Disposition_Edit`, and that set carries a
     * `LOI__c.Disposition_LOI` recordTypeVisibilities entry. A test built on it would find
     * `isAvailable() == true`, take the OLD code path, and pass whether or not the defect is
     * fixed. It is the right fixture for the SHARING question and the wrong one for this one.
     *
     * ── 🔴 WHY `DPEG_Acquisition_View`, WHICH LOOKS LIKE THE WRONG MODULE ────────────────────
     * DELIBERATE, AND IT IS THE WHOLE POINT OF THIS FIXTURE. Two constraints have to hold at once:
     *   1. `LOI__c` must be READABLE. This repo has measured (see `createNonOwnerDispositionApprover`
     *      and `TaskFanoutService`) that Apex throws `System.TypeException: DML operation … not
     *      allowed on X` for an object the running user has no access to at all, and the
     *      production principal DID hold `LOI__c` read — a persona with zero access would fail for
     *      a reason that is not the defect.
     *   2. `LOI__c.Disposition_LOI` must NOT be visible — and must STAY invisible as the org's
     *      permission sets evolve.
     * `DPEG_Disposition_View` satisfies (1) but stopped satisfying (2) on 2026-08-25, when the
     * five disposition recordTypeVisibilities entries were added to it as the other half of this
     * same fix. `DPEG_Acquisition_View` satisfies both, and satisfies (2) STRUCTURALLY rather than
     * by accident: it is an acquisition-side set, and a disposition record type appearing on it
     * would itself be the defect. Its two entries are `Lead.Acquisition_Broker` and
     * `LOI__c.Acquisition_LOI`, neither of which affects `Disposition_LOI`'s availability.
     *
     * ⚠ CALLERS MUST ASSERT THE PRECONDITION THEMSELVES, INSIDE `System.runAs`, and must assert it
     * as a HARD failure: `…getRecordTypeInfosByDeveloperName().get('Disposition_LOI').isAvailable()`
     * must be FALSE. Without that assertion this fixture degrades silently into an ordinary user
     * the day someone widens a permission set, and the test it feeds goes vacuously green — which
     * is precisely how the production defect survived every test in this repo.
     *
     * ⚠ THIS PERSONA SEES NO RECORDS AT ALL, AND CALLERS MUST FIX THAT THEMSELVES. It owns nothing
     * and is in no group, so on a Private-OWD object every fixture row is invisible to it — and
     * `AccessLevel.SYSTEM_MODE` does NOT rescue a lookup to an invisible parent (measured
     * 2026-08-25: `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY` from the LOI insert in
     * `DispositionStageEntryService.openDispositionLois`). Insert a manual `<Object>__Share` row as
     * the running admin before the act — never widen the permission sets, which is what would
     * destroy the record-type blindness this fixture exists to provide.
     *
     * ⚠ MIXED_DML: `User` and `PermissionSetAssignment` are setup objects, so both inserts run
     * inside `System.runAs(currentUser)` — the same workaround `createNonOwnerDispositionApprover`
     * uses, for the same reason.
     *
     * ⚠ NO ROLE, deliberately — same reasoning as `createNonOwnerDispositionApprover`: a role would
     * expose the fixture to hierarchy grants that have nothing to do with record types.
     *
     * @param aliasSeed 1-4 lowercase characters identifying the calling test, so a failure names
     *                  which fixture produced the user. Required.
     * @return The inserted User.
     * @example
     * User principal = TestDataFactory.createRecordTypeBlindDispositionPrincipal('rtb');
     * System.runAs(principal) { DispositionStageEntryService.createStageEntryRecords(newList, oldMap); }
     */
    public static User createRecordTypeBlindDispositionPrincipal(String aliasSeed) {
        if (String.isBlank(aliasSeed)) {
            throw new TestDataFactoryException('aliasSeed is required and cannot be blank.');
        }
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        List<PermissionSet> sets = [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN ('DPEG_Base_Access', 'DPEG_Acquisition_View')
        ];
        if (sets.size() != 2) {
            throw new TestDataFactoryException(
                'FIXTURE PRECONDITION FAILED: expected DPEG_Base_Access and DPEG_Acquisition_View '
                + 'to exist in this org; found ' + sets.size() + '. DPEG_Acquisition_View is what '
                + 'grants LOI__c read WITHOUT granting LOI__c.Disposition_LOI visibility — see '
                + 'this method\'s header for why that combination is the fixture. Deploy the '
                + 'permission sets first.');
        }
        String unique = aliasSeed + String.valueOf(DateTime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User principal = new User(
            FirstName = 'RecordTypeBlind',
            LastName = 'Principal',
            Alias = aliasSeed,
            Email = 'dpeg.principal@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert principal;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : sets) {
                assignments.add(new PermissionSetAssignment(
                    AssigneeId = principal.Id,
                    PermissionSetId = ps.Id
                ));
            }
            insert assignments;
        }
        return principal;
    }

    /**
     * @param count           Number of Dispositions.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Dispositions at stage 'Disposition Readiness', record type On_Market.
     */
    public static List<Disposition__c> createDispositions(Integer count, Id propertyAssetId, Boolean doInsert) {
        return createDispositions(count, propertyAssetId, DISPOSITION_RT_ON_MARKET, doInsert);
    }

    /**
     * Dispositions on an explicit record type.
     *
     * 🔴 WHY THE RECORD TYPE IS STAMPED AT ALL. Leaving RecordTypeId unset makes every
     * test's Disposition inherit the TEST-RUNNING USER'S PROFILE DEFAULT — which is org
     * state, is not deployable (`profiles/**` is .forceignore'd), and differs between a
     * scratch org and usman-dpeg. A test whose fixture depends on that is green or red
     * depending on who runs it. Stamping it makes the fixture a property of this file.
     *
     * ⚠ The stamp is GUARDED, not asserted. When the record type does not exist in the org
     * (e.g. the §4 metadata has not deployed yet) RecordTypeId is left unset and the
     * platform default applies. That is deliberate: an undeployed record type must not turn
     * every disposition test in the repo red, and the guard costs one describe. It does
     * mean a green suite is NOT proof the record types deployed — post-deploy gate B4 is.
     *
     * 🔴 RETRACTED 2026-08-19 (flow redesign) — On_Market and Off_Market no longer carry
     * disjoint Disposition_Stage__c value sets; they overlap on nine of eleven values. The
     * retracted claim is quoted rather than deleted because it is exactly what a future reader
     * would assume: "On_Market and Off_Market carry DISJOINT Disposition_Stage__c value sets ...
     * 'BOV Outreach' / 'Active Listing' / 'Call for Offers' are On_Market only, and 'NDA' /
     * 'Disposition Offer' are Off_Market only." NDA is now a stage on BOTH record types (an
     * on-market sale collects a buyer NDA exactly as a direct one does), and so are
     * 'Broker Selection', 'Release Materials', 'Offer Selection' and 'Sale Closes'. This factory
     * still seeds 'Disposition Readiness', which remains valid on both. The only surviving
     * ON_MARKET-only values are 'BOV Outreach' and 'Active Listing' ('Call for Offers' is a
     * doomed value parked for manual deletion, not a live stage). 'Disposition Offer' is doomed
     * too. A caller that moves the record to a path-specific stage must still pick the matching
     * record type for those two on-market-only survivors; every other post-Readiness stage is
     * reachable from either record type.
     *
     * ⚠ Stage is NEVER seeded as 'Completed' or 'Sale Closes'. `Wire_Complete_Before_Sale_Closes`
     * (renamed from Wire_Complete_Before_Completed in the same redesign — a validation-rule
     * API-name change is a delete-plus-create, not a rename) fires on
     * OR(ISNEW(), ISCHANGED(Disposition_Stage__c)) and would refuse the insert unless the derived
     * Wire_Verification_Completed__c were already true — which no brand-new record can be.
     *
     * ⚠ AND SINCE 2026-08-19, MOVING A SAVED DISPOSITION OF EITHER RECORD TYPE PAST NDA IS ALSO
     * GATED. `All_NDAs_Signed_Before_Progression` dropped its Off_Market-only record-type term and
     * now blocks BOTH types from a real `update` DML into Release Materials / Active Listing /
     * Offer Selection / LOI / PSA / Closing / Sale Closes unless every non-Declined NDA on the
     * disposition is Signed. This factory does not sign one, so a caller advancing a fixture past
     * NDA via `update` must do so itself (see DispositionStageEntryServiceTest.signBuyerNdaOn for
     * the pattern) or insert directly at the target stage, where the rule's ISCHANGED-only guard
     * is inert.
     *
     * @param count                   Number of Dispositions.
     * @param propertyAssetId         Parent Property_Asset__c (nullable).
     * @param recordTypeDeveloperName DISPOSITION_RT_ON_MARKET or DISPOSITION_RT_OFF_MARKET.
     * @param doInsert                Insert when true.
     * @return Dispositions at stage 'Disposition Readiness'.
     */
    public static List<Disposition__c> createDispositions(
        Integer count,
        Id propertyAssetId,
        String recordTypeDeveloperName,
        Boolean doInsert
    ) {
        requirePositive(count);
        Id recordTypeId = dispositionRecordTypeId(recordTypeDeveloperName);
        List<Disposition__c> dispositions = new List<Disposition__c>();
        for (Integer i = 0; i < count; i++) {
            dispositions.add(new Disposition__c(
                Property_Asset__c = propertyAssetId,
                Disposition_Stage__c = 'Disposition Readiness',
                Listing_Date__c = Date.today(),
                Submission_Deadline__c = Date.today().addDays(30),
                Closing_Date__c = Date.today().addDays(90),
                Brokers_Contacted__c = 0,
                Responses_Received__c = 0,
                Gross_Sale_Proceeds__c = 1200000 + (i * 1000),
                Selling_Costs__c = 60000,
                Title_Company__c = 'Test Title Co',
                PSA_Executed__c = false,
                // Package_Sent__c is a DATE despite the Boolean-sounding name.
                Package_Sent__c = Date.today(),
                Closing_Statement_Uploaded__c = false
            ));
        }
        if (recordTypeId != null) {
            for (Disposition__c d : dispositions) {
                d.RecordTypeId = recordTypeId;
            }
        }
        insertIf(doInsert, dispositions);
        return dispositions;
    }

    /**
     * Resolves a Disposition__c record type developer name to its Id, or null when it does
     * not exist in this org / is not available to the running user (see the guard rationale
     * on createDispositions). An UNRECOGNISED name is a caller mistake and throws, so a typo
     * fails loudly instead of silently producing a default-record-type fixture.
     *
     * 🔴 THE ALLOW-LIST COMPARISON MUST BE CASE-SENSITIVE, AND `!=` IS NOT. Apex `==` / `!=`
     * on String is case-INSENSITIVE, while `getRecordTypeInfosByDeveloperName()` keys the map
     * case-SENSITIVELY. With `!=` the two disagreed, and the disagreement is exactly the hole
     * this method exists to close: 'on_market' passed the allow-list (case-insensitively
     * equal to the constant), then missed the describe map (case-sensitively different), and
     * returned null — the silent degrade-to-platform-default the throw was written to
     * prevent. `String.equals(Object)` is case-sensitive, so the guard and the lookup now
     * answer the same question. Both constants are non-null literals, so a null argument is
     * simply not equal to either and still throws, unchanged.
     */
    private static Id dispositionRecordTypeId(String recordTypeDeveloperName) {
        if (!DISPOSITION_RT_ON_MARKET.equals(recordTypeDeveloperName)
            && !DISPOSITION_RT_OFF_MARKET.equals(recordTypeDeveloperName)) {
            throw new TestDataFactoryException(
                'Unknown Disposition__c record type: ' + recordTypeDeveloperName
                + '. Expected On_Market or Off_Market.'
            );
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** Dispositions under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Dispositions. */
    public static List<Disposition__c> createDispositions(Integer count, Boolean doInsert) {
        return createDispositions(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Disposition on an explicit record type. @param propertyAssetId Parent asset. @param recordTypeDeveloperName On_Market or Off_Market. @param doInsert Insert when true. @return The Disposition. */
    public static Disposition__c createDisposition(Id propertyAssetId, String recordTypeDeveloperName, Boolean doInsert) {
        return createDispositions(1, propertyAssetId, recordTypeDeveloperName, doInsert)[0];
    }

    /** Single Disposition. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The Disposition. */
    public static Disposition__c createDisposition(Id propertyAssetId, Boolean doInsert) {
        return createDispositions(1, propertyAssetId, doInsert)[0];
    }

    /**
     * 🔴 A DISPOSITION WHOSE **PROPERTY ASSET** CARRIES A KNOWN `Target_Sale_Price__c` — the
     * fixture on which `BOV_Score__c` is non-null AND PREDICTABLE. Added 2026-08-24; REPOINTED
     * FROM THE DISPOSITION TO THE ASSET ON 2026-08-25.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 READ THIS BEFORE TRUSTING ANY SCORE-RELATED FIXTURE — THE DEFAULT INVERTED ON 2026-08-25
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `BOV_Score__c`'s 50-point Value term used to be
     * `BOV_Amount__c / Disposition__r.Asking_Price__c`. `Asking_Price__c` is now retired from the
     * disposition flow and the basis is `Disposition__r.Property_Asset__r.Target_Sale_Price__c` —
     * TWO hops out, on the ASSET.
     *
     * 🔴 THAT MOVE ALMOST INVERTED THIS FACTORY'S LONG-STANDING DEFAULT, AND THE FIX IS ELSEWHERE —
     * READ IT BEFORE CHANGING EITHER PLACE:
     *   BEFORE — `createDispositions` never set `Asking_Price__c`, so every BOV scored NULL. A test
     *            that forgot to price its parent quietly proved nothing.
     *   ALMOST — the basis moved to the ASSET, and `createPropertyAssets` shipped
     *            `Target_Sale_Price__c = 1200000 + (i*1000)` on every asset it built. That would
     *            have made a Disposition under ANY factory asset SCOREABLE BY DEFAULT, so every
     *            test meaning to exercise the null-score branch would have quietly proved the
     *            OPPOSITE — the same defect pointing the other way, and invisible in both.
     *   NOW    — that default was REMOVED from `createPropertyAssets` in the same change (its own
     *            comment carries the argument). The suite-wide default is null-scored again.
     * ⇒ Set the basis EXPLICITLY: this method for a pinned, known value; `unpriceAsset(...)` below
     *   when a test has already priced the asset and needs it blank again.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHY IT IS STILL A SEPARATE METHOD RATHER THAN A FLAG ON `createDispositions`
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * Because a test that asserts a RANKING needs the basis PINNED, not merely non-null, and the
     * pinned value has to be chosen against the BOV amounts. `createBovSubmissions` uses
     * `BOV_Amount__c = 1200000 + (i*1000)`; a basis at or below that makes every row saturate the
     * formula's `MIN(ratio, 1.10)` cap, so the scores come out non-null AND ALL EQUAL and a ranking
     * test is decided by the tie-break while looking like it passed. Pass an `askingPrice` well
     * ABOVE the amounts to keep the Value term strictly increasing in `BOV_Amount__c`.
     *
     * 🔴 IT WRITES TO THE **ASSET**, NOT THE DISPOSITION, AND THAT HAS A BLAST RADIUS.
     * `propertyAssetId` is UPDATED in place, so EVERY disposition under that asset — including ones
     * built earlier in the same test — becomes priced at the same basis. A test that needs a priced
     * AND an unpriced disposition in ONE transaction must use TWO assets. (Checked 2026-08-25: no
     * test in this repo does; `BovAutoSelectionServiceTest` uses one or the other per test method,
     * never both.) It also fires `PropertyAssetTrigger` and therefore `BovAutoSelectionService`'s
     * asset hook — cheap here because it runs before this method's dispositions exist, but do not
     * call it inside a `Limits` measurement window.
     *
     * ⚠ USE IT WITH `createBovSubmissions(count, dispositionId, ...)` — count > 1 — TO GET
     * DIFFERING, NON-NULL SCORES, AND HERE IS EXACTLY WHY THAT WORKS. That method sets
     * `BOV_Amount__c = 1200000 + (i * 1000)` and holds `Commission_Rate__c` (2.5) and
     * `Days_To_Market__c` (30) CONSTANT across the rows, so with a fixed asking price the Value
     * term — and therefore the whole score — is STRICTLY INCREASING IN `i`: the LAST row built is
     * the highest scorer. At the default `askingPrice` below, adjacent rows differ by ~0.03, which
     * survives the field's `scale = 2` rounding, so no two adjacent rows tie. A test that wants a
     * DELIBERATE tie must set two rows to the SAME `BOV_Amount__c` by hand.
     *
     * ⚠ A test that needs a non-null score and does NOT use this method is VACUOUS — it exercises
     * the "no scoreable candidate" branch of `BovAutoSelectionService` and nothing else, while
     * looking like a full test. That is the single most likely way this feature ships untested.
     *
     * @param count           Number of Dispositions.
     * @param propertyAssetId Parent Property_Asset__c. 🔴 REQUIRED SINCE 2026-08-25 — the price
     *                        lives on the ASSET now, so an asset-less "priced" disposition is a
     *                        contradiction that would score null. It throws rather than build one.
     * @param askingPrice     `Target_Sale_Price__c` written to THAT ASSET, and therefore the value
     *                        basis for every BOV under every disposition on it. Must be > 0 — a
     *                        null or `<= 0` basis is exactly the state this method exists to avoid.
     * @param doInsert        Insert the Dispositions when true. ⚠ The ASSET is updated either way:
     *                        the basis must be in place before any score is read, and an unsaved
     *                        Disposition has no score to read regardless.
     * @return Dispositions at stage 'Disposition Readiness', record type On_Market, under an asset
     *         priced at `askingPrice`.
     * @example
     * Disposition__c d = TestDataFactory.createPricedDisposition(assetId, 1500000, false);
     * d.Disposition_Stage__c = 'BOV Outreach';
     * insert d;
     * TestDataFactory.createBovSubmissions(3, d.Id, true); // three DIFFERING non-null scores
     */
    public static List<Disposition__c> createPricedDispositions(
        Integer count,
        Id propertyAssetId,
        Decimal askingPrice,
        Boolean doInsert
    ) {
        if (askingPrice == null || askingPrice <= 0) {
            throw new TestDataFactoryException(
                'createPricedDispositions requires a POSITIVE askingPrice; got ' + askingPrice
                + '. BOV_Score__c returns null for a blank or non-positive Target_Sale_Price__c, so '
                + 'this fixture would produce exactly the all-null scores it exists to avoid — and '
                + 'every auto-selection assertion built on it would pass without exercising '
                + 'anything.');
        }
        if (propertyAssetId == null) {
            throw new TestDataFactoryException(
                'createPricedDispositions requires a propertyAssetId since 2026-08-25: '
                + 'BOV_Score__c\'s value basis is Disposition__r.Property_Asset__r.'
                + 'Target_Sale_Price__c, so a Disposition with no asset can never be "priced" and '
                + 'every score under it would be null. Pass the asset whose price you want pinned.');
        }
        // 🔴 THE PRICE GOES ON THE ASSET. See this method's header for the blast radius: every
        // disposition under this asset is scored against `askingPrice` from here on.
        update new Property_Asset__c(Id = propertyAssetId, Target_Sale_Price__c = askingPrice);
        List<Disposition__c> dispositions = createDispositions(
            count, propertyAssetId, DISPOSITION_RT_ON_MARKET, false);
        insertIf(doInsert, dispositions);
        return dispositions;
    }

    /**
     * 🔴 THE DELIBERATE NULL-SCORE FIXTURE — clears `Target_Sale_Price__c` on an asset so that
     * every BOV under every disposition on it scores NULL. Added 2026-08-25.
     *
     * ⚠ IT IS **NOT** NEEDED TO GET THE DEFAULT — `createPropertyAssets` no longer ships a target
     * sale price (removed 2026-08-25; read its comment), so a plain factory asset is already
     * unpriced. This method exists for the case a plain `createDisposition` cannot cover: a test
     * that has ALREADY priced the asset — directly, or via `createPricedDisposition` — and now
     * needs the blank state back within the SAME transaction. Calling it defensively at the top of
     * a null-score fixture is cheap and states the intent, which is why
     * `BovAutoSelectionServiceTest.unpricedDispositionAt` does exactly that.
     *
     * ⚠ ONE ASSET, TRANSACTION-WIDE. It blanks the basis for EVERY disposition on that asset.
     *
     * ⚠ CALL IT BEFORE BUILDING THE BOV ROWS AND OUTSIDE ANY `Limits` MEASUREMENT WINDOW: it is a
     * real `update` on `Property_Asset__c`, so it fires `PropertyAssetTrigger` ->
     * `BovAutoSelectionService`'s asset hook, which costs a query once dispositions exist.
     *
     * @param propertyAssetId the asset to blank. Required.
     */
    public static void unpriceAsset(Id propertyAssetId) {
        requireId(propertyAssetId, 'propertyAssetId (TestDataFactory.unpriceAsset)');
        update new Property_Asset__c(Id = propertyAssetId, Target_Sale_Price__c = null);
    }

    /** Single priced Disposition. @param propertyAssetId Parent asset (required). @param askingPrice Positive Target_Sale_Price__c stamped on that asset. @param doInsert Insert when true. @return The Disposition. */
    public static Disposition__c createPricedDisposition(
        Id propertyAssetId,
        Decimal askingPrice,
        Boolean doInsert
    ) {
        return createPricedDispositions(1, propertyAssetId, askingPrice, doInsert)[0];
    }

    /**
     * @param count         Number of Disposition Offers.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Offers at status 'Received'.
     */
    public static List<Disposition_Offer__c> createDispositionOffers(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();
        for (Integer i = 0; i < count; i++) {
            offers.add(new Disposition_Offer__c(
                Disposition__c = dispositionId,
                Offer_Status__c = 'Received',
                Buyer_Name__c = 'Test Buyer ' + i,
                Offer_Amount__c = 1150000 + (i * 1000),
                Offer_Date__c = Date.today(),
                Earnest_Money_Proposed__c = 50000,
                Due_Diligence_Days__c = 30,
                Closing_Period_Days__c = 30
            ));
        }
        insertIf(doInsert, offers);
        return offers;
    }

    /** Disposition Offers under the shared scaffold Disposition. @param count Number. @param doInsert Insert when true. @return Offers. */
    public static List<Disposition_Offer__c> createDispositionOffers(Integer count, Boolean doInsert) {
        return createDispositionOffers(count, defaultDisposition().Id, doInsert);
    }

    /** Single Disposition Offer. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The offer. */
    public static Disposition_Offer__c createDispositionOffer(Id dispositionId, Boolean doInsert) {
        return createDispositionOffers(1, dispositionId, doInsert)[0];
    }

    /**
     * count == 1 reuses the shared per-transaction `defaultBrokerContact()` so a caller looping
     * over the SINGULAR `createBovSubmission(...)` convenience method many times in one
     * transaction — a real, measured pattern (`BovSubmissionSelectionGuardTest
     * .bulk251BecomingSelected...`, `BovSubmissionTriggerHandlerTest.bulk251ApprovesAtConstantCost`,
     * both call it 251 times) — does not issue 251 separate Contact-insert DML statements and blow
     * the 150-DML-statement governor limit. count > 1 creates COUNT distinct broker Contacts in
     * exactly ONE bulk insert, so a genuine bulk caller (`createBovSubmissions(251, ...)`) still
     * gets 251 distinct, fully-formed brokers for one extra DML statement.
     */
    private static List<Id> bovBrokerContactIdsFor(Integer count) {
        if (count == 1) {
            return new List<Id>{ defaultBrokerContact().Id };
        }
        List<Contact> brokers = createBrokerContacts(count, null, true);
        List<Id> ids = new List<Id>();
        for (Contact broker : brokers) {
            ids.add(broker.Id);
        }
        return ids;
    }

    /**
     * @param count         Number of BOV Submissions.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return BOV Submissions at status 'Backup'.
     *
     * ── 🔴 Broker__c IS SET, ADDED 2026-08-20 (requirements §3 D1) ────────────────────────────
     * `Broker_Required_On_Submission` (Tranche 2, Workstream A1) makes `Broker__c` a mandatory,
     * unguarded invariant on EVERY save of this object — see that rule file's own header. This
     * factory therefore always attaches a real broker Contact (`Is_Broker__c = true`, satisfying
     * the field's active, non-optional lookup filter) via `bovBrokerContactIdsFor`, regardless of
     * `doInsert`: the lookup must reference an already-persisted Contact whether or not the
     * SUBMISSION itself is inserted here.
     * ⚠ `Broker_Firm__c` / `Contact_Name__c` ARE STILL SET HERE, but `BovSubmissionBrokerStampService`
     * OVERWRITES both the instant this record is actually inserted (Broker__c goes from
     * oldMap-null to non-null, which is always "changed" on insert) — see that service's header
     * ("the stamp wins"). Do not write a test that assumes these two literals survive a real insert
     * without also pointing Broker__c at a Contact carrying the value it expects
     * (`createBrokerContactWithFirm`). They still matter for the UNSAVED (`doInsert = false`) state
     * a caller may inspect before performing its own insert.
     *
     * ── 🔴 `BOV_Score__c` IS DELIBERATELY NOT SET, REMOVED 2026-08-21 ─────────────────────────
     * This factory used to write `BOV_Score__c = 80` on EVERY submission it built. The field is
     * being recreated as a FORMULA, and a formula field CANNOT BE ASSIGNED IN APEX — that one line
     * was a compile error waiting to happen in the single class every other test class depends on,
     * i.e. the whole suite and every `RunLocalTests` deploy. It is removed AHEAD of the conversion
     * so the cutover is a metadata-only change.
     *
     * ⚠ WHAT REPLACES IT: THE FORMULA'S INPUTS, WHICH THIS FACTORY ALREADY SET. THE FORMULA IS
     * THREE DIMENSIONS, NOT FIVE (user-approved weights, 2026-08-21): `BOV_Amount__c` (Price,
     * 50 pts, measured against `Disposition__r.Property_Asset__r.Target_Sale_Price__c` since
     * 2026-08-25 — it was `Disposition__r.Asking_Price__c` until then), `Commission_Rate__c`
     * (Commission, 25 pts, lower is better) and `Days_To_Market__c` (Speed, 25 pts, lower is
     * better). `Cap_Rate__c` and `Hist_Success_Rate__c` are still populated above for other
     * consumers of this fixture but carry NO WEIGHT in `BOV_Score__c` — `Hist_Success_Rate__c` is
     * null on every row in the org today, and giving it weight would collapse every score to null.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 RETRACTED TWICE. THE CURRENT ANSWER IS: **THESE FIXTURES ARE SCOREABLE BY DEFAULT.**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     *   V1 said `Disposition__r.Asking_Price__c` "does not exist on `Disposition__c` yet." ❌ It
     *      did exist (`objects/Disposition__c/fields/Asking_Price__c.field-meta.xml`).
     *   V2 said "every fixture built here still scores null, because the Dispositions this factory
     *      builds do not set `Asking_Price__c`." ✅ STILL TRUE, BUT NOT FOR THAT REASON ANY MORE,
     *      and the difference is what a future reader needs. The basis moved to the PROPERTY ASSET
     *      on 2026-08-25, where `createPropertyAssets` DID ship `Target_Sale_Price__c = 1200000 +
     *      (i*1000)` — which would have made every fixture here scoreable and silently inverted
     *      every null-score test in the repo. That default was removed in the same change. The
     *      conclusion holds; the mechanism behind it does not.
     * ⇒ A BOV built here still scores NULL unless its Disposition's ASSET is priced. ⚠ And when
     *   you do price it, pick the basis deliberately: against this factory's own
     *   `BOV_Amount__c = 1200000 + i*1000`, a target at or below 1,200,000 saturates the formula's
     *   `MIN(ratio, 1.10)` cap and every row TIES — non-null, all equal, and a ranking test reads
     *   "non-null" as proof. Use `createPricedDisposition(...)` with a basis ABOVE the amounts.
     * Do not reintroduce a `BOV_Score__c` assignment here to make such a test possible — it will
     * not compile: the field is a formula.
     */
    public static List<BOV_Submission__c> createBovSubmissions(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<Id> brokerIds = bovBrokerContactIdsFor(count);
        List<BOV_Submission__c> submissions = new List<BOV_Submission__c>();
        for (Integer i = 0; i < count; i++) {
            submissions.add(new BOV_Submission__c(
                Disposition__c = dispositionId,
                Submission_Status__c = 'Backup',
                Broker__c = brokerIds[i],
                Broker_Firm__c = 'Test Brokerage ' + i,
                Contact_Name__c = 'Test Broker ' + i,
                BOV_Amount__c = 1200000 + (i * 1000),
                Cap_Rate__c = 6.25,
                Commission_Rate__c = 2.5,
                Days_To_Market__c = 30,
                Hist_Success_Rate__c = 75
            ));
        }
        insertIf(doInsert, submissions);
        return submissions;
    }

    /** BOV Submissions under the shared scaffold Disposition. @param count Number. @param doInsert Insert when true. @return Submissions. */
    public static List<BOV_Submission__c> createBovSubmissions(Integer count, Boolean doInsert) {
        return createBovSubmissions(count, defaultDisposition().Id, doInsert);
    }

    /** Single BOV Submission. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The submission. */
    public static BOV_Submission__c createBovSubmission(Id dispositionId, Boolean doInsert) {
        return createBovSubmissions(1, dispositionId, doInsert)[0];
    }

    /**
     * BOV broker-change history rows — the append-only log written by
     * `BovSubmissionService.replaceSelectedBroker` (added 2026-08-20, Tranche 2 Workstream B).
     *
     * ⚠ THIS BUILDS A ROW BY HAND, WHICH IS ONLY EVER CORRECT IN A *READ* TEST. In production
     * nothing may insert this object except the replacement it records — a fixture row is a
     * shortcut for exercising `BovBrokerChangeSelector` / `BovBrokerChangeController` without
     * performing a whole broker swap per row, NOT a sanctioned way to create history. A test of
     * the WRITE must call the service.
     *
     * ⚠ BOTH Contact LOOKUPS ARE LEFT NULL. `Outgoing_Broker__c` / `Incoming_Broker__c` carry an
     * ACTIVE, NON-OPTIONAL lookup filter (`Contact.Is_Broker__c = true`) enforced on Apex DML, so a
     * fixture that pointed them at an ordinary `createContact` Contact would fail at insert with
     * the filter's error rather than at the assertion. A caller that needs them populated should
     * use `createBrokerContactWithFirm(...)`, which produces a Contact the filter accepts.
     * ⚠ `Entry_DateTime__c` IS SET EXPLICITLY AND DESCENDS BY ONE MINUTE PER INDEX, so a caller can
     * assert the selector's newest-first ORDER BY without depending on insert order or on the
     * frozen test clock (every row in one transaction otherwise shares a DateTime to the
     * millisecond, leaving only the `Name DESC` tie-break to prove).
     *
     * @param count         Number of history rows.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Broker-change rows, index 0 the NEWEST.
     */
    public static List<BOV_Broker_Change__c> createBovBrokerChanges(
            Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        Datetime base = Datetime.now();
        List<BOV_Broker_Change__c> changes = new List<BOV_Broker_Change__c>();
        for (Integer i = 0; i < count; i++) {
            changes.add(new BOV_Broker_Change__c(
                Disposition__c = dispositionId,
                Outgoing_Broker_Firm__c = 'Outgoing Brokerage ' + i,
                Incoming_Broker_Firm__c = 'Incoming Brokerage ' + i,
                Reason__c = 'Performance Issue',
                Notes__c = 'Test broker change ' + i,
                Entry_DateTime__c = base.addMinutes(-i),
                Logged_By__c = UserInfo.getUserId()
            ));
        }
        insertIf(doInsert, changes);
        return changes;
    }

    /** Single BOV broker change. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The change row. */
    public static BOV_Broker_Change__c createBovBrokerChange(Id dispositionId, Boolean doInsert) {
        return createBovBrokerChanges(1, dispositionId, doInsert)[0];
    }

    /**
     * Release Materials responses for a Disposition — the log behind `c/releaseMaterialsResponseLog`
     * and the second source of the merged Buyer Activity timeline. Added 2026-08-24.
     *
     * ⚠ THIS IS A FIXTURE SHORTCUT, NOT A SANCTIONED WAY TO CREATE A RESPONSE. Production rows come
     * from `ReleaseMaterialsResponseService.logResponse`, which RESOLVES the broker from the parent
     * rather than accepting one. A test of the WRITE must call the service; this exists so a test of
     * a READ (the selector, the logger's list, the merged timeline) does not have to stage a broker
     * appointment per row.
     *
     * ⚠ `Broker__c` IS LEFT NULL AND MUST BE SET BY THE CALLER IF IT NEEDS ONE. The field carries an
     * ACTIVE, NON-OPTIONAL lookup filter (`Contact.RecordType.DeveloperName = 'Broker'`) which Apex
     * DML enforces, so pointing it at an ordinary `createContact` Contact fails at INSERT with
     * `FIELD_FILTER_VALIDATION_EXCEPTION` — a failure that reads like a defect in the code under
     * test. Use `createBrokerContact(...)`, which produces a Contact the filter accepts.
     * ⚠ A NULL BROKER IS ALSO THE REALISTIC DEFAULT: the service logs a response with a blank broker
     * whenever none is appointed yet, and that is an accepted, non-blocking outcome.
     *
     * ⚠ `Entry_DateTime__c` IS SET EXPLICITLY AND DESCENDS BY ONE MINUTE PER INDEX, so index 0 is
     * the NEWEST. Without it every row in one transaction shares a DateTime to the millisecond
     * (the test clock is frozen), leaving only a tie-break to prove and making any ordering
     * assertion — the selector's `DESC`, or the merged timeline's — vacuous. It also overrides the
     * field's `NOW()` default, which is what a test asserting on order must do.
     *
     * ⚠ `Method__c` CYCLES THROUGH ALL THREE RESTRICTED VALUES so a fixture of three or more rows
     * exercises every badge the card can render. The value set is `restricted` and Apex DML enforces
     * it, so a typo here fails at insert rather than at the assertion.
     *
     * @param count         Number of responses.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Responses, index 0 the NEWEST.
     */
    public static List<Release_Materials_Response__c> createReleaseMaterialsResponses(
            Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<String> methods = new List<String>{ 'More questions', 'Decision', 'Offer' };
        Datetime base = Datetime.now();
        List<Release_Materials_Response__c> responses = new List<Release_Materials_Response__c>();
        for (Integer i = 0; i < count; i++) {
            responses.add(new Release_Materials_Response__c(
                Disposition__c = dispositionId,
                Method__c = methods[Math.mod(i, methods.size())],
                Notes__c = 'Test release materials response ' + i,
                Entry_DateTime__c = base.addMinutes(-i)
            ));
        }
        insertIf(doInsert, responses);
        return responses;
    }

    /**
     * Single Release Materials response.
     *
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return The response row, `Method__c = 'More questions'`, no broker.
     */
    public static Release_Materials_Response__c createReleaseMaterialsResponse(
            Id dispositionId, Boolean doInsert) {
        return createReleaseMaterialsResponses(1, dispositionId, doInsert)[0];
    }

    /**
     * @param count         Number of Broker Listings.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Broker Listings at status 'On Track'.
     */
    public static List<Broker_Listing__c> createBrokerListings(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<Broker_Listing__c> listings = new List<Broker_Listing__c>();
        for (Integer i = 0; i < count; i++) {
            listings.add(new Broker_Listing__c(
                Disposition__c = dispositionId,
                Listing_Status__c = 'On Track',
                Broker_Firm__c = 'Test Brokerage ' + i,
                Contact_Name__c = 'Test Broker ' + i,
                List_Date__c = Date.today(),
                Call_For_Offers_Date__c = Date.today().addDays(30),
                Commission_Percent__c = 2.5,
                Days_On_Market__c = 0,
                Offers_Received__c = 0
            ));
        }
        insertIf(doInsert, listings);
        return listings;
    }

    /** Broker Listings under the shared scaffold Disposition. @param count Number. @param doInsert Insert when true. @return Listings. */
    public static List<Broker_Listing__c> createBrokerListings(Integer count, Boolean doInsert) {
        return createBrokerListings(count, defaultDisposition().Id, doInsert);
    }

    /** Single Broker Listing. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The listing. */
    public static Broker_Listing__c createBrokerListing(Id dispositionId, Boolean doInsert) {
        return createBrokerListings(1, dispositionId, doInsert)[0];
    }

    /**
     * Wires. Parents to Disposition__c.
     * ⚠ CORRECTED 2026-08-31: this used to say "there is no Wire__c -> Transaction__c
     * relationship in this org". There is one now (Phase 1 schema). This overload still
     * parents to Disposition__c deliberately — see the block comment above.
     * @param count         Number of Wires.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Wires.
     */
    public static List<Wire__c> createWires(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<Wire__c> wires = new List<Wire__c>();
        for (Integer i = 0; i < count; i++) {
            wires.add(new Wire__c(
                Disposition__c = dispositionId,
                Confirmed_Wire_Amount__c = 50000 + (i * 100),
                Verbal_Verification_Completed__c = false,
                Verifier_Name__c = 'Test Verifier ' + i,
                Verifier_Phone__c = '713-555-' + String.valueOf(i).leftPad(4, '0'),
                Wire_Instructions_Source__c = 'Test Source'
            ));
        }
        insertIf(doInsert, wires);
        return wires;
    }

    /** Wires under the shared scaffold Disposition. @param count Number. @param doInsert Insert when true. @return Wires. */
    public static List<Wire__c> createWires(Integer count, Boolean doInsert) {
        return createWires(count, defaultDisposition().Id, doInsert);
    }

    /** Single Wire. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The Wire. */
    public static Wire__c createWire(Id dispositionId, Boolean doInsert) {
        return createWires(1, dispositionId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — ONBOARDING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count           Number of Onboardings.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Onboardings at stage 'Property Set up', PRE-FLAGGED as already fanned out.
     *
     * 🔴 `Tasks_Fanned_Out__c = true` IS DELIBERATE AND LOAD-BEARING — READ BEFORE
     * REMOVING IT. The `Onboarding_Task_Fanout` flow fires on any `Onboarding__c` with a
     * non-null `Start_Date__c` and `Tasks_Fanned_Out__c = false`, and this factory sets
     * `Start_Date__c`. Without the flag, EVERY factory-built Onboarding in the suite would
     * enqueue a checklist fan-out that materialises 45 Tasks at `Test.stopTest()` — and
     * those Tasks fire `TaskRollupTrigger`, which recomputes the parent's counters. Every
     * existing exact-count assertion (`Assert.areEqual(4, r.Tasks_Total__c, ...)` in
     * `OnboardingTaskRollupServiceTest`, the checklist assertions in
     * `OnboardingControllerTest`) would then be measuring 49 rows, not 4.
     *
     * Setting it here makes the whole pre-existing suite immune BY CONSTRUCTION — the same
     * technique, for the same reason, as keying the onboarding auto-create on
     * `Property_Asset__c.Closing_Date__c`, which this factory also leaves blank.
     *
     * ⚠ A test that WANTS the fan-out must clear it explicitly:
     *     Onboarding__c o = TestDataFactory.createOnboarding(assetId, false);
     *     o.Tasks_Fanned_Out__c = false;
     *     insert o;
     * `OnboardingFanoutServiceTest` does exactly that and is the only class that should.
     */
    public static List<Onboarding__c> createOnboardings(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Onboarding__c> onboardings = new List<Onboarding__c>();
        for (Integer i = 0; i < count; i++) {
            onboardings.add(new Onboarding__c(
                Property_Asset__c = propertyAssetId,
                Stage__c = 'Property Set up',
                Status__c = 'In Progress',
                Onboarding_Lead__c = UserInfo.getUserId(),
                Start_Date__c = Date.today(),
                Target_Completion_Date__c = Date.today().addDays(30),
                Tasks_Fanned_Out__c = true,
                Tasks_Total__c = 0,
                Tasks_Complete__c = 0,
                Tasks_Open__c = 0,
                Tasks_Not_Started__c = 0,
                Tasks_In_Progress__c = 0,
                Tasks_Blocked__c = 0,
                Tasks_Overdue__c = 0
            ));
        }
        insertIf(doInsert, onboardings);
        return onboardings;
    }

    /** Onboardings under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Onboardings. */
    public static List<Onboarding__c> createOnboardings(Integer count, Boolean doInsert) {
        return createOnboardings(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Onboarding. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The Onboarding. */
    public static Onboarding__c createOnboarding(Id propertyAssetId, Boolean doInsert) {
        return createOnboardings(1, propertyAssetId, doInsert)[0];
    }

    /**
     * IN-MEMORY `Onboarding_Task_Def__mdt` rows for the checklist fan-out.
     *
     * ⚠ CUSTOM METADATA CANNOT BE INSERTED IN A TEST, but it CAN be constructed in
     * memory — which is the entire reason `OnboardingFanoutService.taskDefsOverride`
     * exists. Assign the result to that seam; do not try to `insert` these.
     *
     * ⚠ AND THE REAL ROWS ARE NOT IN THE REPO. `.forceignore` excludes
     * the customMetadata directory glob, so the 45 production rows are loaded asynchronously by
     * `scripts/load-onboarding-task-defs.apex`. A test that relies on the ORG's rows is
     * therefore order-dependent and will behave differently in a freshly built scratch
     * org. Use this builder instead.
     *
     * Values match the shape the real rows carry: `Category__c` and `Source_System__c`
     * are drawn from the RESTRICTED picklists on `Task.Onboarding_Category__c` /
     * `Task.Source_System__c` (restricted picklists ARE enforced by DML in this org, so
     * an off-list value fails the fan-out insert at runtime, not at compile time).
     *
     * @param count Number of definition rows (sequence 1..count, offsets 0..count-1).
     * @return Unsaved, un-insertable Onboarding_Task_Def__mdt rows.
     */
    public static List<Onboarding_Task_Def__mdt> buildOnboardingTaskDefs(Integer count) {
        requirePositive(count);
        List<String> categories = new List<String>{
            'Property Set up', 'Unit & Tenant Setup', 'Vendor & Expense Management',
            'NNN Reconciliation & Billing Setup', 'Tenant Communication & Transition',
            'Performance Tracking', 'Leasing'
        };
        List<String> sources = new List<String>{ 'Yardi', 'Excel', 'Salesforce', 'Email' };
        List<Onboarding_Task_Def__mdt> defs = new List<Onboarding_Task_Def__mdt>();
        for (Integer i = 0; i < count; i++) {
            // ⚠ No DeveloperName / MasterLabel: those are system fields on a __mdt sObject
            // and are not needed by any consumer. `TaskFanoutServiceTest` sets neither.
            defs.add(new Onboarding_Task_Def__mdt(
                Category__c = categories[Math.mod(i, categories.size())],
                Subject__c = 'Test checklist item ' + i,
                Sequence__c = i + 1,
                Owner_Label__c = 'Isha Patel',
                Source_System__c = sources[Math.mod(i, sources.size())],
                Due_Day_Offset__c = i,
                Default_Status__c = 'Not Started',
                Conditional__c = false
            ));
        }
        return defs;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — LEASING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Lease inquiries. Tenant_Name__c is schema-required.
     * Broker__c is intentionally NOT defaulted — its lookup filter demands a
     * Contact with Is_Broker__c = true. Use createBrokerContacts() and override.
     * @param count           Number of Lease Inquiries.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Lease Inquiries at stage 'Inquiry Received'.
     */
    public static List<Lease_Inquiry__c> createLeaseInquiries(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Lease_Inquiry__c> inquiries = new List<Lease_Inquiry__c>();
        for (Integer i = 0; i < count; i++) {
            inquiries.add(new Lease_Inquiry__c(
                Property_Asset__c = propertyAssetId,
                Tenant_Name__c = 'Test Tenant ' + i,
                Stage__c = 'Inquiry Received',
                Ball_In_Court__c = 'Landlord',
                Handling_Person__c = UserInfo.getUserId(),
                Inquiry_Date__c = Date.today(),
                Stage_Start_Date__c = Date.today(),
                Space_Required__c = 1000 + (i * 10),
                // Base_Rent__c / TI_Allowance__c are TEXT (blessed quoted-deal-term Text),
                // not Currency/Number — see the type-inversion note in the class header.
                // Lease_Term_Months__c / Free_Rent_Months__c are typed Number(months) per §1 rule 9 (Wave D).
                Base_Rent__c = String.valueOf(5000 + (i * 10)),
                Lease_Term_Months__c = 60,
                Free_Rent_Months__c = 2,
                TI_Allowance__c = '25',
                Initial_Notes__c = 'Test inquiry ' + i
            ));
        }
        insertIf(doInsert, inquiries);
        return inquiries;
    }

    /** Lease Inquiries under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Inquiries. */
    public static List<Lease_Inquiry__c> createLeaseInquiries(Integer count, Boolean doInsert) {
        return createLeaseInquiries(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Lease Inquiry. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The inquiry. */
    public static Lease_Inquiry__c createLeaseInquiry(Id propertyAssetId, Boolean doInsert) {
        return createLeaseInquiries(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Lease activities. Lease_Inquiry__c is a MASTER-DETAIL parent — mandatory.
     * @param count          Number of Lease Activities.
     * @param leaseInquiryId Master Lease_Inquiry__c (required).
     * @param doInsert       Insert when true.
     * @return Lease Activities.
     */
    public static List<Lease_Activity__c> createLeaseActivities(Integer count, Id leaseInquiryId, Boolean doInsert) {
        requirePositive(count);
        requireId(leaseInquiryId, 'leaseInquiryId (Lease_Activity__c.Lease_Inquiry__c is Master-Detail)');
        Datetime entryStamp = System.now();
        List<Lease_Activity__c> activities = new List<Lease_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Lease_Activity__c(
                Lease_Inquiry__c = leaseInquiryId,
                Ball_In_Court__c = 'Landlord',
                Entry_DateTime__c = entryStamp, // ARCHITECTURE.md §1 rule-9 stamp
                Logged_By__c = UserInfo.getUserId(),
                Details__c = 'Test lease activity ' + i
            ));
        }
        insertIf(doInsert, activities);
        return activities;
    }

    /** Lease Activities under the shared scaffold inquiry. @param count Number. @param doInsert Insert when true. @return Activities. */
    public static List<Lease_Activity__c> createLeaseActivities(Integer count, Boolean doInsert) {
        return createLeaseActivities(count, defaultLeaseInquiry().Id, doInsert);
    }

    /** Single Lease Activity. @param leaseInquiryId Master inquiry. @param doInsert Insert when true. @return The activity. */
    public static Lease_Activity__c createLeaseActivity(Id leaseInquiryId, Boolean doInsert) {
        return createLeaseActivities(1, leaseInquiryId, doInsert)[0];
    }

    /**
     * Leases. BOTH Lease_Inquiry__c and Stage__c are schema-required.
     * @param count          Number of Leases.
     * @param leaseInquiryId Parent Lease_Inquiry__c (required).
     * @param doInsert       Insert when true.
     * @return Leases at stage 'Draft'.
     */
    public static List<Lease__c> createLeases(Integer count, Id leaseInquiryId, Boolean doInsert) {
        requirePositive(count);
        requireId(leaseInquiryId, 'leaseInquiryId (Lease__c.Lease_Inquiry__c is required)');
        List<Lease__c> leases = new List<Lease__c>();
        for (Integer i = 0; i < count; i++) {
            leases.add(new Lease__c(
                Lease_Inquiry__c = leaseInquiryId,
                Stage__c = 'Draft',
                Legal_Owner__c = UserInfo.getUserId(),
                Target_Execution_Date__c = Date.today().addDays(30)
            ));
        }
        insertIf(doInsert, leases);
        return leases;
    }

    /** Leases under the shared scaffold inquiry. @param count Number. @param doInsert Insert when true. @return Leases. */
    public static List<Lease__c> createLeases(Integer count, Boolean doInsert) {
        return createLeases(count, defaultLeaseInquiry().Id, doInsert);
    }

    /** Single Lease. @param leaseInquiryId Parent inquiry. @param doInsert Insert when true. @return The Lease. */
    public static Lease__c createLease(Id leaseInquiryId, Boolean doInsert) {
        return createLeases(1, leaseInquiryId, doInsert)[0];
    }

    /**
     * Broker assignments. Broker__c is left null by default — its lookup filter
     * requires Contact.Is_Broker__c = true. Use createBrokerAssignments(count,
     * assetId, brokerId, doInsert) with a Contact from createBrokerContacts().
     * @param count           Number of Broker Assignments.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param brokerContactId Broker Contact (must have Is_Broker__c = true); nullable.
     * @param doInsert        Insert when true.
     * @return Broker Assignments at status 'Active'.
     */
    public static List<Broker_Assignment__c> createBrokerAssignments(
        Integer count,
        Id propertyAssetId,
        Id brokerContactId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Broker_Assignment__c> assignments = new List<Broker_Assignment__c>();
        for (Integer i = 0; i < count; i++) {
            assignments.add(new Broker_Assignment__c(
                Property_Asset__c = propertyAssetId,
                Broker__c = brokerContactId,
                Status__c = 'Active',
                Listing_Start_Date__c = Date.today().addDays(-30),
                Listing_End_Date__c = Date.today().addDays(335),
                Last_Check_In_Date__c = Date.today()
            ));
        }
        insertIf(doInsert, assignments);
        return assignments;
    }

    /** Broker Assignments under the shared scaffold asset with a fresh broker Contact. @param count Number. @param doInsert Insert when true. @return Assignments. */
    public static List<Broker_Assignment__c> createBrokerAssignments(Integer count, Boolean doInsert) {
        Contact broker = createBrokerContacts(1, null, true)[0];
        return createBrokerAssignments(count, defaultPropertyAsset().Id, broker.Id, doInsert);
    }

    /** Single Broker Assignment. @param propertyAssetId Parent asset. @param brokerContactId Broker Contact. @param doInsert Insert when true. @return The assignment. */
    public static Broker_Assignment__c createBrokerAssignment(
        Id propertyAssetId,
        Id brokerContactId,
        Boolean doInsert
    ) {
        return createBrokerAssignments(1, propertyAssetId, brokerContactId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — RENEWALS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Lease renewals. BOTH Tenant_Name__c and Lease_End__c are schema-required.
     * Unit_Label__c on this object is a TEXT field, not a lookup to Unit__c.
     * @param count           Number of Lease Renewals.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Lease Renewals at stage 'Not Yet Started'.
     */
    public static List<Lease_Renewal__c> createLeaseRenewals(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Lease_Renewal__c> renewals = new List<Lease_Renewal__c>();
        for (Integer i = 0; i < count; i++) {
            renewals.add(new Lease_Renewal__c(
                Property_Asset__c = propertyAssetId,
                Tenant_Name__c = 'Test Tenant ' + i,
                Lease_End__c = Date.today().addDays(120),
                Lease_Start__c = Date.today().addYears(-3),
                Stage__c = 'Not Yet Started',
                Handling_Person__c = UserInfo.getUserId(),
                Unit_Label__c = 'Suite ' + (100 + i),
                Current_Rent__c = String.valueOf(5000 + (i * 10)), // TEXT, not Currency
                Proposed_Rate__c = 5250 + (i * 10),
                Space_Sq_Ft__c = 1000 + (i * 10),
                Has_Renewal_Option__c = true,
                Last_Contact_Date__c = Date.today()
            ));
        }
        insertIf(doInsert, renewals);
        return renewals;
    }

    /** Lease Renewals under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Renewals. */
    public static List<Lease_Renewal__c> createLeaseRenewals(Integer count, Boolean doInsert) {
        return createLeaseRenewals(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Lease Renewal. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The renewal. */
    public static Lease_Renewal__c createLeaseRenewal(Id propertyAssetId, Boolean doInsert) {
        return createLeaseRenewals(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Renewal activities. Lease_Renewal__c is a MASTER-DETAIL parent — mandatory.
     * @param count          Number of Renewal Activities.
     * @param leaseRenewalId Master Lease_Renewal__c (required).
     * @param doInsert       Insert when true.
     * @return Renewal Activities.
     */
    public static List<Renewal_Activity__c> createRenewalActivities(Integer count, Id leaseRenewalId, Boolean doInsert) {
        requirePositive(count);
        requireId(leaseRenewalId, 'leaseRenewalId (Renewal_Activity__c.Lease_Renewal__c is Master-Detail)');
        Datetime entryStamp = System.now();
        List<Renewal_Activity__c> activities = new List<Renewal_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Renewal_Activity__c(
                Lease_Renewal__c = leaseRenewalId,
                Method__c = 'Call',
                Entry_DateTime__c = entryStamp, // ARCHITECTURE.md §1 rule-9 stamp
                Details__c = 'Test renewal activity ' + i
            ));
        }
        insertIf(doInsert, activities);
        return activities;
    }

    /** Renewal Activities under the shared scaffold renewal. @param count Number. @param doInsert Insert when true. @return Activities. */
    public static List<Renewal_Activity__c> createRenewalActivities(Integer count, Boolean doInsert) {
        return createRenewalActivities(count, defaultLeaseRenewal().Id, doInsert);
    }

    /** Single Renewal Activity. @param leaseRenewalId Master renewal. @param doInsert Insert when true. @return The activity. */
    public static Renewal_Activity__c createRenewalActivity(Id leaseRenewalId, Boolean doInsert) {
        return createRenewalActivities(1, leaseRenewalId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — MAINTENANCE (YARDI MIRRORS)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Work orders. Subject__c is schema-required; Reported_DateTime__c anchors every
     * SLA formula, so it is set deterministically rather than relying on CreatedDate.
     * Ownership uses Owner_User__c (a lookup), NOT the standard OwnerId. Unit_Label__c
     * here is a TEXT field (may hold non-unit values such as 'Common' - it was never a
     * unit reference).
     *
     * Reported_DateTime__c is the ARCHITECTURE.md §1 rule-9 SLA anchor. To override it
     * on a returned record, use createWorkOrdersReportedAt.
     * @param count           Number of Work Orders.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Work Orders at status 'New'.
     */
    public static List<Work_Order__c> createWorkOrders(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        Datetime reportedStamp = System.now().addHours(-1);
        List<Work_Order__c> workOrders = new List<Work_Order__c>();
        for (Integer i = 0; i < count; i++) {
            workOrders.add(new Work_Order__c(
                Property_Asset__c = propertyAssetId,
                Subject__c = 'Test Work Order ' + i,
                Reported_DateTime__c = reportedStamp, // ARCHITECTURE.md §1 rule-9 SLA anchor
                Status__c = 'New',
                Priority__c = 'Medium',
                Category__c = 'General',
                Owner_User__c = UserInfo.getUserId(),
                Owner_Role__c = 'Maintenance',
                Tenant_Name__c = 'Test Tenant ' + i,
                Unit_Label__c = 'Suite ' + (100 + i),
                Vendor__c = 'Test Vendor ' + i,
                Description__c = 'Test work order description ' + i
            ));
        }
        insertIf(doInsert, workOrders);
        return workOrders;
    }

    /** Work Orders under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Work Orders. */
    public static List<Work_Order__c> createWorkOrders(Integer count, Boolean doInsert) {
        return createWorkOrders(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Work Order. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The Work Order. */
    public static Work_Order__c createWorkOrder(Id propertyAssetId, Boolean doInsert) {
        return createWorkOrders(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Work orders with an explicit reported timestamp — use this to drive the SLA
     * formula tiers (24/48/168/360h) deterministically instead of sleeping.
     *
     * Sets Reported_DateTime__c to reportedDate — the ARCHITECTURE.md §1 rule-9 SLA anchor.
     * @param count           Number of Work Orders.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param reportedDate    Value for Reported_DateTime__c (SLA anchor).
     * @param doInsert        Insert when true.
     * @return Work Orders.
     */
    public static List<Work_Order__c> createWorkOrdersReportedAt(
        Integer count,
        Id propertyAssetId,
        DateTime reportedDate,
        Boolean doInsert
    ) {
        if (reportedDate == null) {
            throw new TestDataFactoryException('reportedDate is required; Work_Order__c.Reported_DateTime__c anchors all SLA math.');
        }
        List<Work_Order__c> workOrders = createWorkOrders(count, propertyAssetId, false);
        for (Work_Order__c workOrder : workOrders) {
            workOrder.Reported_DateTime__c = reportedDate; // ARCHITECTURE.md §1 rule-9 SLA anchor
        }
        insertIf(doInsert, workOrders);
        return workOrders;
    }

    /**
     * Work order activities. Work_Order__c is a MASTER-DETAIL parent — mandatory.
     * @param count       Number of Work Order Activities.
     * @param workOrderId Master Work_Order__c (required).
     * @param doInsert    Insert when true.
     * @return Work Order Activities.
     */
    public static List<Work_Order_Activity__c> createWorkOrderActivities(
        Integer count,
        Id workOrderId,
        Boolean doInsert
    ) {
        requirePositive(count);
        requireId(workOrderId, 'workOrderId (Work_Order_Activity__c.Work_Order__c is Master-Detail)');
        Datetime entryStamp = System.now();
        List<Work_Order_Activity__c> activities = new List<Work_Order_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Work_Order_Activity__c(
                Work_Order__c = workOrderId,
                Kind__c = 'Sync',
                Entry_DateTime__c = entryStamp, // ARCHITECTURE.md §1 rule-9 stamp
                Actor__c = 'Test Actor ' + i,
                Detail__c = 'Test work order activity ' + i
            ));
        }
        insertIf(doInsert, activities);
        return activities;
    }

    /** Work Order Activities under the shared scaffold Work Order. @param count Number. @param doInsert Insert when true. @return Activities. */
    public static List<Work_Order_Activity__c> createWorkOrderActivities(Integer count, Boolean doInsert) {
        return createWorkOrderActivities(count, defaultWorkOrder().Id, doInsert);
    }

    /** Single Work Order Activity. @param workOrderId Master Work Order. @param doInsert Insert when true. @return The activity. */
    public static Work_Order_Activity__c createWorkOrderActivity(Id workOrderId, Boolean doInsert) {
        return createWorkOrderActivities(1, workOrderId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — FINANCE MIRRORS
    // The three Yardi external ids below are UNIQUE, so they are counter-backed.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count           Number of CAM Reconciliations.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return CAM Reconciliations at status 'Pending'.
     */
    public static List<CAM_Reconciliation__c> createCamReconciliations(
        Integer count,
        Id propertyAssetId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<CAM_Reconciliation__c> reconciliations = new List<CAM_Reconciliation__c>();
        for (Integer i = 0; i < count; i++) {
            reconciliations.add(new CAM_Reconciliation__c(
                Property_Asset__c = propertyAssetId,
                Status__c = 'Pending',
                Amount__c = 10000 + (i * 100),
                Reconciliation_Year__c = String.valueOf(Date.today().year()), // TEXT, not Number
                Yardi_CAM_Id__c = 'YC-' + String.valueOf(nextUnique()).leftPad(10, '0')
            ));
        }
        insertIf(doInsert, reconciliations);
        return reconciliations;
    }

    /** CAM Reconciliations under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Reconciliations. */
    public static List<CAM_Reconciliation__c> createCamReconciliations(Integer count, Boolean doInsert) {
        return createCamReconciliations(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single CAM Reconciliation. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The reconciliation. */
    public static CAM_Reconciliation__c createCamReconciliation(Id propertyAssetId, Boolean doInsert) {
        return createCamReconciliations(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Delinquencies. Aging_Bucket__c has no picklist default, so it is set.
     * @param count           Number of Delinquencies.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Delinquencies.
     */
    public static List<Delinquency__c> createDelinquencies(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Delinquency__c> delinquencies = new List<Delinquency__c>();
        for (Integer i = 0; i < count; i++) {
            delinquencies.add(new Delinquency__c(
                Property_Asset__c = propertyAssetId,
                Aging_Bucket__c = '1-30 Days',
                Balance__c = 1000 + (i * 10),
                Tenant_Name__c = 'Test Tenant ' + i,
                Unit_Suite__c = 'Suite ' + (100 + i),
                Yardi_AR_Id__c = 'YA-' + String.valueOf(nextUnique()).leftPad(10, '0')
            ));
        }
        insertIf(doInsert, delinquencies);
        return delinquencies;
    }

    /** Delinquencies under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Delinquencies. */
    public static List<Delinquency__c> createDelinquencies(Integer count, Boolean doInsert) {
        return createDelinquencies(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Delinquency. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The delinquency. */
    public static Delinquency__c createDelinquency(Id propertyAssetId, Boolean doInsert) {
        return createDelinquencies(1, propertyAssetId, doInsert)[0];
    }

    /**
     * @param count           Number of Insurance Policies.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Insurance Policies.
     */
    public static List<Insurance_Policy__c> createInsurancePolicies(
        Integer count,
        Id propertyAssetId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Insurance_Policy__c> policies = new List<Insurance_Policy__c>();
        for (Integer i = 0; i < count; i++) {
            policies.add(new Insurance_Policy__c(
                Property_Asset__c = propertyAssetId,
                Policy_Name__c = 'Test Policy ' + i,
                Carrier__c = 'Test Carrier ' + i,
                Expiry_Date__c = Date.today().addDays(180),
                Yardi_Policy_Id__c = 'YP-' + String.valueOf(nextUnique()).leftPad(10, '0')
            ));
        }
        insertIf(doInsert, policies);
        return policies;
    }

    /** Insurance Policies under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Policies. */
    public static List<Insurance_Policy__c> createInsurancePolicies(Integer count, Boolean doInsert) {
        return createInsurancePolicies(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Insurance Policy. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The policy. */
    public static Insurance_Policy__c createInsurancePolicy(Id propertyAssetId, Boolean doInsert) {
        return createInsurancePolicies(1, propertyAssetId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BROKER PROTECTION (Property_Registry__c / Competing_Broker_Submission__c)
    //
    // Both objects carry an insert-scoped Winning_Lead_Required validation rule
    // (AND(ISNEW(), ISBLANK(Winning_Lead__c))) — Winning_Lead__c is required on
    // insert but may legally be nulled afterward (SetNull on Lead delete; also how
    // PropertyMatchingService.findOrphanedRegistry's "orphan" row is simulated in
    // tests: insert with a winner, then update Winning_Lead__c to null).
    //
    // Property_Registry__c.Property_Key__c is UNIQUE + case-insensitive, so the
    // bulk factory method mints a counter-backed key per row; tests that need a
    // caller-controlled key (exact-match / fuzzy-match / race-collision scenarios)
    // use the explicit-key single-record overload instead.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Property_Registry__c winner rows, each with its own unique Property_Key__c
     * (counter-backed) so bulk calls never collide on the unique index.
     * @param count         Number of registry rows.
     * @param winningLeadId Winning_Lead__c (required by the VR on insert).
     * @param doInsert      Insert when true.
     * @return Property_Registry__c rows.
     */
    /**
     * ⚠ THIS GUARD IS STILL CORRECT — DO NOT "HARMONIZE" IT WITH THE SUBMISSION FACTORY.
     * Checked 2026-08-03 when Competing_Broker_Submission__c gained its Opportunity anchor.
     * Property_Registry__c deliberately did NOT: its `Winning_Lead__c` is only ever written with
     * a Lead created milliseconds earlier (which cannot be converted yet) or re-pointed on an
     * orphan row whose lookup is already null, so it is never exposed to the converted-Lead
     * rejection and its own Winning_Lead_Required VR is unchanged. Requiring the Lead here
     * remains the accurate rule. See PropertyClaimService.registerWinner's prohibition note.
     */
    public static List<Property_Registry__c> createPropertyRegistries(Integer count, Id winningLeadId, Boolean doInsert) {
        requirePositive(count);
        requireId(winningLeadId, 'winningLeadId (Property_Registry__c.Winning_Lead__c is required on insert)');
        List<Property_Registry__c> registries = new List<Property_Registry__c>();
        for (Integer i = 0; i < count; i++) {
            String key = 'test property key ' + nextUnique();
            registries.add(new Property_Registry__c(
                Property_Key__c = key,
                Normalized_Address__c = key,
                Winning_Lead__c = winningLeadId,
                Registered_DateTime__c = Datetime.now()
            ));
        }
        insertIf(doInsert, registries);
        return registries;
    }

    /** Single Property Registry with an auto-generated unique key. @param winningLeadId Winning_Lead__c (required). @param doInsert Insert when true. @return The registry row. */
    public static Property_Registry__c createPropertyRegistry(Id winningLeadId, Boolean doInsert) {
        return createPropertyRegistries(1, winningLeadId, doInsert)[0];
    }

    /**
     * Single Property Registry with a caller-controlled Property_Key__c — needed
     * for exact-match / fuzzy-match / unique-index-collision test scenarios where
     * the test must control the key value directly rather than accept an
     * auto-generated one.
     * @param propertyKey   Exact Property_Key__c / Normalized_Address__c value.
     * @param winningLeadId Winning_Lead__c (required by the VR on insert).
     * @param doInsert      Insert when true.
     * @return The registry row.
     */
    public static Property_Registry__c createPropertyRegistry(String propertyKey, Id winningLeadId, Boolean doInsert) {
        requireId(winningLeadId, 'winningLeadId (Property_Registry__c.Winning_Lead__c is required on insert)');
        Property_Registry__c registry = new Property_Registry__c(
            Property_Key__c = propertyKey,
            Normalized_Address__c = propertyKey,
            Winning_Lead__c = winningLeadId,
            Registered_DateTime__c = Datetime.now()
        );
        insertIf(doInsert, new List<Property_Registry__c>{ registry });
        return registry;
    }

    /**
     * Competing_Broker_Submission__c rows against one winning Lead. Submitted_DateTime__c
     * ascends with index (starting 1 day ago) and Is_Winning_Submission__c is true only
     * at index 0, so the factory's own "winner" row is also the chronologically-earliest
     * one — matching the real invariant (selectByWinningLead orders ASC, earliest first).
     * ⚠ THE WINNER ANCHOR IS SPLIT ACROSS TWO FIELDS (2026-08-03). A submission names its winner
     * as EITHER `Winning_Lead__c` (the winning Lead is still open) OR `Winning_Opportunity__c`
     * (it has been converted — the platform rejects a lookup SET to a converted Lead). These
     * Lead-only overloads build the FIRST shape and keep their original guard; use the
     * `winningOpportunityId` overloads below for the second. See PropertyClaimService's WINNER
     * ANCHOR note and the widened Winning_Lead_Required validation rule.
     *
     * @param count         Number of submissions.
     * @param winningLeadId Winning_Lead__c (required on this overload).
     * @param doInsert      Insert when true.
     * @return Competing_Broker_Submission__c rows.
     */
    public static List<Competing_Broker_Submission__c> createCompetingBrokerSubmissions(
        Integer count,
        Id winningLeadId,
        Boolean doInsert
    ) {
        requireId(winningLeadId, 'winningLeadId (Competing_Broker_Submission__c.Winning_Lead__c is required on insert)');
        return createCompetingBrokerSubmissions(count, winningLeadId, null, doInsert);
    }

    /**
     * Competing_Broker_Submission__c rows against a winner named by EITHER anchor.
     *
     * ═══ WHY THIS OVERLOAD EXISTS ═══
     * The Lead-only signature above encoded "Winning_Lead__c is required on insert", which was
     * true until 2026-08-03 and is now only HALF the rule. It rejected the exact shape the
     * winner-anchor fix introduces — an Opportunity-anchored row with both Lead lookups null —
     * and no test could build a post-conversion submission at all.
     *
     * 🔴 THE GUARD IS NOT REMOVED, IT IS RESTATED TO MATCH THE VALIDATION RULE: at least one
     * anchor must be supplied. Dropping the check entirely would let a test build a row the org
     * would reject, turning a clear factory error into a confusing DML failure at the call site —
     * which is the whole reason this factory validates rather than trusting its callers.
     *
     * ⚠ AN OPPORTUNITY-ANCHORED ROW GETS `Source_Lead__c = null` TOO, and that is the real
     * production shape rather than a simplification: per that field's contract a persisted
     * `Source_Lead__c` is either null or equal to `Winning_Lead__c`, so once the winner is
     * converted it is the same unwritable Lead.
     *
     * @param count                Number of submissions.
     * @param winningLeadId        Winning_Lead__c, or null when anchoring on the Opportunity.
     * @param winningOpportunityId Winning_Opportunity__c, or null when anchoring on the Lead.
     * @param doInsert             Insert when true.
     * @return Competing_Broker_Submission__c rows.
     * @throws TestDataFactoryException when neither anchor is supplied, or when an Id is of the
     *         wrong SObject type (the two parameters are adjacent and same-typed).
     */
    public static List<Competing_Broker_Submission__c> createCompetingBrokerSubmissions(
        Integer count,
        Id winningLeadId,
        Id winningOpportunityId,
        Boolean doInsert
    ) {
        requirePositive(count);
        if (winningLeadId == null && winningOpportunityId == null) {
            throw new TestDataFactoryException(
                'A Competing_Broker_Submission__c needs a winner anchor: supply winningLeadId '
                + '(open winner) OR winningOpportunityId (converted winner). The '
                + 'Winning_Lead_Required validation rule rejects a row with neither.');
        }
        requireSObjectType(winningLeadId, Lead.SObjectType, 'winningLeadId');
        requireSObjectType(winningOpportunityId, Opportunity.SObjectType, 'winningOpportunityId');

        Datetime base = Datetime.now().addDays(-1);
        List<Competing_Broker_Submission__c> subs = new List<Competing_Broker_Submission__c>();
        for (Integer i = 0; i < count; i++) {
            Integer u = nextUnique();
            subs.add(new Competing_Broker_Submission__c(
                Winning_Lead__c = winningLeadId,
                Winning_Opportunity__c = winningOpportunityId,
                // Null on the Opportunity path: the source Lead is the same converted Lead, which
                // is equally unwritable. Only the Lead-anchored shape carries one.
                Source_Lead__c = winningLeadId,
                Broker_Name__c = 'Test Broker ' + i,
                Broker_Email__c = 'test.broker' + u + '@example.invalid',
                Forwarded_By_Email__c = 'test.forwarder' + u + '@example.invalid',
                Property_Address_Raw__c = i + ' Test Submission Street',
                Submitted_DateTime__c = base.addMinutes(i),
                Email_Subject__c = 'FW: Test property ' + i,
                Is_Winning_Submission__c = (i == 0)
            ));
        }
        insertIf(doInsert, subs);
        return subs;
    }

    /** Single Competing Broker Submission (winning), anchored on an OPEN Lead. @param winningLeadId Winning_Lead__c (required). @param doInsert Insert when true. @return The submission. */
    public static Competing_Broker_Submission__c createCompetingBrokerSubmission(Id winningLeadId, Boolean doInsert) {
        return createCompetingBrokerSubmissions(1, winningLeadId, doInsert)[0];
    }

    /**
     * Single Competing Broker Submission anchored on EITHER a Lead or an Opportunity — the
     * post-conversion shape. Pass exactly one; see the bulk overload for the full rationale.
     *
     * @param winningLeadId        Winning_Lead__c, or null when anchoring on the Opportunity.
     * @param winningOpportunityId Winning_Opportunity__c, or null when anchoring on the Lead.
     * @param doInsert             Insert when true.
     * @return The submission.
     * @example
     * // A submission written after the winning Lead was converted:
     * TestDataFactory.createCompetingBrokerSubmission(null, opportunityId, true);
     */
    public static Competing_Broker_Submission__c createCompetingBrokerSubmission(
        Id winningLeadId,
        Id winningOpportunityId,
        Boolean doInsert
    ) {
        return createCompetingBrokerSubmissions(1, winningLeadId, winningOpportunityId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BROKER PROTECTION — CONCURRENCY CONTROL (W4)
    //
    // Property_Claim_Lock__c is a pure lock-partition object: one row per COARSE
    // address cluster (Cluster_Key__c is unique + externalId + required, no parent
    // lookups). PropertyClaimService.claim() get-or-creates this row and takes a
    // FOR UPDATE lock on it before deciding a winner. The bulk method mints a
    // counter-backed key per row so concurrent factory calls in one transaction
    // never collide on the unique index; the explicit-key overload is for tests
    // that must control the exact cluster key (get-or-create / lock scenarios).
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Property_Claim_Lock__c rows, each with its own unique Cluster_Key__c
     * (counter-backed) so bulk calls never collide on the unique index.
     * @param count    Number of lock rows.
     * @param doInsert Insert when true.
     * @return Property_Claim_Lock__c rows.
     */
    public static List<Property_Claim_Lock__c> createPropertyClaimLocks(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Property_Claim_Lock__c> locks = new List<Property_Claim_Lock__c>();
        for (Integer i = 0; i < count; i++) {
            locks.add(new Property_Claim_Lock__c(
                Cluster_Key__c = 'test cluster key ' + nextUnique()
            ));
        }
        insertIf(doInsert, locks);
        return locks;
    }

    /** Single Property Claim Lock with an auto-generated unique cluster key. @param doInsert Insert when true. @return The lock row. */
    public static Property_Claim_Lock__c createPropertyClaimLock(Boolean doInsert) {
        return createPropertyClaimLocks(1, doInsert)[0];
    }

    /**
     * Single Property Claim Lock with a caller-controlled Cluster_Key__c — needed for
     * get-or-create / FOR UPDATE lock-acquisition scenarios where the test must control
     * the key value directly rather than accept an auto-generated one.
     * @param clusterKey Exact Cluster_Key__c value.
     * @param doInsert   Insert when true.
     * @return The lock row.
     */
    public static Property_Claim_Lock__c createPropertyClaimLock(String clusterKey, Boolean doInsert) {
        Property_Claim_Lock__c lockRow = new Property_Claim_Lock__c(Cluster_Key__c = clusterKey);
        insertIf(doInsert, new List<Property_Claim_Lock__c>{ lockRow });
        return lockRow;
    }

    // ===========================================================================
    // FSD 5.10 - UTILITY & METER TRACKING
    //
    // 1. `createUtilityBills` LEAVES `Consumption__c` NULL ON PURPOSE, AND THAT IS THE
    //   SINGLE MOST IMPORTANT LINE IN THIS BLOCK. `UtilityBillService.isManualOverride`
    //   treats ANY non-null consumption on insert as a human override and refuses to
    //   recompute it. A factory that helpfully populated the field would therefore switch
    //   off the rollover / meter-swap engine for every test that uses it - every consumption
    //   assertion would be asserting the factory's own literal back at itself and the whole
    //   suite would be green by construction. Overrides are set explicitly by the one test
    //   that is actually testing overrides.
    //
    // 2. `Register_Size__c = 5` MEANS `Register_Modulus__c = 100000`. Modulus is a FORMULA
    //   derived from register size (a value of 12 or less is read as a DIAL COUNT, more as a
    //   modulus), so it cannot be set directly and is null on an un-inserted record. A test
    //   asserting rollover arithmetic must re-query the meter, or hard-code 100000 knowing
    //   where it came from.
    //
    // 3. THREE OF THESE FIVE OBJECTS ARE MASTER-DETAIL CHILDREN and their parent is
    //   mandatory: Utility_Bill__c -> Meter__c, Charge_Line__c -> Utility_Bill__c,
    //   Meter_Allocation__c -> Meter__c. Meter__c -> Property_Asset__c is a LOOKUP and is
    //   technically optional, but a meter with no property is invisible on every register
    //   list in the app, so it is required here too.
    //
    // 4. Meter -> Utility Bill -> Charge Line is a THREE-LEVEL master-detail chain, which is
    //   the platform maximum. Nothing can be added below Charge_Line__c as a detail.
    // ===========================================================================

    /**
     * Meters on the register. Whole-building by default (Unit__c left null - FSD 5.10.4
     * makes a blank space meaningful data, not missing data).
     *
     * Meter_Number__c and Service_Identifier__c are counter-backed so two calls in one
     * transaction cannot collide. Service_Identifier__c in particular is what
     * `MeterCaptureService` uses to detect service-point reuse, so a repeated value would
     * make that warning fire in unrelated tests.
     *
     * @param count           Number of meters.
     * @param propertyAssetId Property_Asset__c the meters are installed at (required).
     * @param doInsert        Insert when true.
     * @return Meters.
     */
    public static List<Meter__c> createMeters(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        requireId(propertyAssetId, 'propertyAssetId (Meter__c.Property_Asset__c)');
        List<Meter__c> meters = new List<Meter__c>();
        for (Integer i = 0; i < count; i++) {
            Integer u = nextUnique();
            meters.add(new Meter__c(
                Property_Asset__c = propertyAssetId,
                Meter_Number__c = 'MTR-' + String.valueOf(u).leftPad(8, '0'),
                Utility_Type__c = 'Electricity',
                Utility_Account_Number__c = 'ACCT-' + String.valueOf(u).leftPad(8, '0'),
                Service_Identifier__c = 'ESID-' + String.valueOf(u).leftPad(10, '0'),
                Provider_Name__c = 'Test Utility Provider',
                Paid_By__c = 'Management',
                Register_Size__c = 5,
                Service_Status__c = 'Active'
            ));
        }
        insertIf(doInsert, meters);
        return meters;
    }

    /** Meters under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Meters. */
    public static List<Meter__c> createMeters(Integer count, Boolean doInsert) {
        return createMeters(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Meter. @param propertyAssetId Property asset. @param doInsert Insert when true. @return The meter. */
    public static Meter__c createMeter(Id propertyAssetId, Boolean doInsert) {
        return createMeters(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Utility bills forming a CONSECUTIVE MONTHLY SEQUENCE on one meter, oldest first.
     *
     * Bill i is read on the 1st of the month (i - count) months from today, so index 0 is
     * the oldest and index count-1 is the newest - which is the order the prior-bill chain
     * links them in. Readings ascend by 100 per bill starting at 1000, so no bill in the
     * default sequence ever reads downwards and none of them exercise the rollover branch by
     * accident. Bill_Date__c is deliberately 5 days AFTER Read_Date__c: FSD 5.10.5 requires
     * the two to be captured separately and the chain is ordered by the READ date, so a
     * fixture where they coincide could not catch a class that sorted by the wrong one.
     *
     * `Consumption__c` IS LEFT NULL. See note 1 in the block comment above.
     *
     * @param count    Number of bills.
     * @param meterId  Master Meter__c (required).
     * @param doInsert Insert when true.
     * @return Bills, oldest read date first.
     */
    public static List<Utility_Bill__c> createUtilityBills(Integer count, Id meterId, Boolean doInsert) {
        requirePositive(count);
        requireId(meterId, 'meterId (Utility_Bill__c.Meter__c is Master-Detail)');
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>();
        for (Integer i = 0; i < count; i++) {
            Date readDate = Date.today().toStartOfMonth().addMonths(i - count);
            bills.add(new Utility_Bill__c(
                Meter__c = meterId,
                Read_Date__c = readDate,
                Bill_Date__c = readDate.addDays(5),
                Previous_Reading__c = 1000 + (i * 100),
                Current_Reading__c = 1100 + (i * 100)
            ));
        }
        insertIf(doInsert, bills);
        return bills;
    }

    /** Bills under the shared scaffold Meter. @param count Number. @param doInsert Insert when true. @return Bills. */
    public static List<Utility_Bill__c> createUtilityBills(Integer count, Boolean doInsert) {
        return createUtilityBills(count, defaultMeter().Id, doInsert);
    }

    /** Single Utility Bill. @param meterId Master meter. @param doInsert Insert when true. @return The bill. */
    public static Utility_Bill__c createUtilityBill(Id meterId, Boolean doInsert) {
        return createUtilityBills(1, meterId, doInsert)[0];
    }

    /**
     * Charge components on one bill. The amounts are DISTINCT per index (100, 110, 120, ...)
     * so a test asserting the roll-up total or a component's share cannot pass on a
     * coincidence of equal values.
     *
     * @param count    Number of charge lines.
     * @param billId   Master Utility_Bill__c (required).
     * @param doInsert Insert when true.
     * @return Charge lines.
     */
    public static List<Charge_Line__c> createChargeLines(Integer count, Id billId, Boolean doInsert) {
        requirePositive(count);
        requireId(billId, 'billId (Charge_Line__c.Utility_Bill__c is Master-Detail)');
        List<String> types = new List<String>{ 'Energy', 'Pass-Through', 'Taxes', 'Base Charge', 'Other' };
        List<Charge_Line__c> lines = new List<Charge_Line__c>();
        for (Integer i = 0; i < count; i++) {
            lines.add(new Charge_Line__c(
                Utility_Bill__c = billId,
                Charge_Type__c = types[Math.mod(i, types.size())],
                Charge_Amount__c = 100 + (i * 10)
            ));
        }
        insertIf(doInsert, lines);
        return lines;
    }

    /** Single Charge Line. @param billId Master bill. @param doInsert Insert when true. @return The charge line. */
    public static Charge_Line__c createChargeLine(Id billId, Boolean doInsert) {
        return createChargeLines(1, billId, doInsert)[0];
    }

    /**
     * One charge line carrying an EXACT amount - for tests that need the bill total, and
     * therefore Rate_Per_Unit__c and every variance figure downstream of it, to be a known
     * number rather than whatever the indexed default produced.
     *
     * @param billId   Master bill.
     * @param amount   Exact Charge_Amount__c.
     * @param doInsert Insert when true.
     * @return The charge line.
     */
    public static Charge_Line__c createChargeLine(Id billId, Decimal amount, Boolean doInsert) {
        requireId(billId, 'billId (Charge_Line__c.Utility_Bill__c is Master-Detail)');
        Charge_Line__c line = new Charge_Line__c(
            Utility_Bill__c = billId,
            Charge_Type__c = 'Energy',
            Charge_Amount__c = amount
        );
        insertIf(doInsert, new List<Charge_Line__c>{ line });
        return line;
    }

    /**
     * Meter allocations - the split of one shared meter across several spaces (FSD 5.10.3).
     *
     * Allocation_Pct__c is `100 / count` so a full set sums to 100 and the meter's
     * Total_Allocated_Pct__c roll-up reads as fully allocated. For a count that does not
     * divide 100 exactly the sum will NOT be 100 (3 gives 99.99 at scale 2) - a test
     * asserting the roll-up must either use a divisor of 100 or assert the value it
     * computes, never the literal 100.
     *
     * @param count    Number of allocations.
     * @param meterId  Master Meter__c (required).
     * @param unitId   Unit__c each allocation points at; may be null.
     * @param doInsert Insert when true.
     * @return Allocations.
     */
    public static List<Meter_Allocation__c> createMeterAllocations(
            Integer count, Id meterId, Id unitId, Boolean doInsert) {
        requirePositive(count);
        requireId(meterId, 'meterId (Meter_Allocation__c.Meter__c is Master-Detail)');
        Decimal share = (Decimal.valueOf(100) / count).setScale(2, System.RoundingMode.DOWN);
        List<Meter_Allocation__c> allocations = new List<Meter_Allocation__c>();
        for (Integer i = 0; i < count; i++) {
            allocations.add(new Meter_Allocation__c(
                Meter__c = meterId,
                Unit__c = unitId,
                Allocation_Basis__c = 'Square Footage',
                Allocation_Pct__c = share
            ));
        }
        insertIf(doInsert, allocations);
        return allocations;
    }

    /** Single Meter Allocation. @param meterId Master meter. @param unitId Unit. @param doInsert Insert when true. @return The allocation. */
    public static Meter_Allocation__c createMeterAllocation(Id meterId, Id unitId, Boolean doInsert) {
        return createMeterAllocations(1, meterId, unitId, doInsert)[0];
    }

    /**
     * Vendor contracts - the fixed-monthly arrangements with no meter and no consumption
     * (FSD 5.10.3: trash and maintenance). Deliberately OUTSIDE the utility bill pipeline;
     * nothing in the consumption or variance path reads these.
     *
     * End_Date__c is a year out, so the default fixture is ACTIVE and the `activeOnly = true`
     * branch of VendorContractSelector returns it. A test for the expired branch must set
     * End_Date__c into the past explicitly.
     *
     * @param count           Number of contracts.
     * @param propertyAssetId Property_Asset__c (required).
     * @param doInsert        Insert when true.
     * @return Vendor contracts.
     */
    public static List<Vendor_Contract__c> createVendorContracts(
            Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        requireId(propertyAssetId, 'propertyAssetId (Vendor_Contract__c.Property_Asset__c)');
        List<String> serviceTypes = new List<String>{ 'Trash', 'Maintenance' };
        List<Vendor_Contract__c> contracts = new List<Vendor_Contract__c>();
        for (Integer i = 0; i < count; i++) {
            contracts.add(new Vendor_Contract__c(
                Property_Asset__c = propertyAssetId,
                Provider_Name__c = 'Test Vendor ' + nextUnique(),
                Service_Type__c = serviceTypes[Math.mod(i, serviceTypes.size())],
                Monthly_Amount__c = 250 + (i * 5),
                Start_Date__c = Date.today().addMonths(-6),
                End_Date__c = Date.today().addMonths(12)
            ));
        }
        insertIf(doInsert, contracts);
        return contracts;
    }

    /** Vendor contracts under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Contracts. */
    public static List<Vendor_Contract__c> createVendorContracts(Integer count, Boolean doInsert) {
        return createVendorContracts(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Vendor Contract. @param propertyAssetId Property asset. @param doInsert Insert when true. @return The contract. */
    public static Vendor_Contract__c createVendorContract(Id propertyAssetId, Boolean doInsert) {
        return createVendorContracts(1, propertyAssetId, doInsert)[0];
    }
}
