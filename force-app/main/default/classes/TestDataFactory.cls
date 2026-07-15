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
 *   - Transaction__c.Wire_Approval_Due__c   is a CHECKBOX (sounds like a Date)
 *   - Counter_Offer__c.Revision_Number__c   is TEXT       (says "Number")
 *   - Deal_Message__c.Revision__c           is TEXT       (sounds like a Number)
 *
 *   Do not type from the field name — check the metadata. This factory got all
 *   four wrong on the first pass WITH the metadata open; the compiler caught them.
 *   `Revision_Number__c` typed as Text is the sharpest case: the name contains the
 *   word "Number" and it is not one. This defect class is the evidence behind the
 *   type-suffix rule in ARCHITECTURE.md §1.
 *
 *   Related: nine money/duration fields are TEXT, not Currency/Number, against
 *   ARCHITECTURE.md §1's naming convention — Lease_Inquiry__c.Base_Rent__c,
 *   .Lease_Term__c, .Free_Rent__c, .TI_Allowance__c; Lease_Renewal__c.Current_Rent__c;
 *   Development_Feasibility_Review__c.Est_Cost_Impact__c, .Proposals_Target__c;
 *   Construction_Feasibility_Review__c.Estimated_Timeline_Impact__c;
 *   CAM_Reconciliation__c.Reconciliation_Year__c. They take String literals here.
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
 *    - StageName 'PSA' also creates a Contract_Review__c (+ Opp update).
 *    - StageName 'Underwriting' also creates an Underwriting__c (+ Opp update).
 *    - 'Development Review' / 'Construction Review' create feasibility reviews.
 *  Default stage is therefore 'New' (valid in both business processes) to keep
 *  the blast radius to the unavoidable NDA. Tests asserting NDA__c counts must
 *  account for the auto-created one.
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

    private static void requirePositive(Integer count) {
        if (count == null || count < 1) {
            throw new TestDataFactoryException('count must be a positive integer; received: ' + count);
        }
    }

    private static void requireId(Id value, String label) {
        if (value == null) {
            throw new TestDataFactoryException(label + ' is required and cannot be null.');
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
    private static Work_Order__c cachedWorkOrder;
    private static Contract_Review__c cachedContractReview;
    private static LOI__c cachedLoi;
    private static Underwriting__c cachedUnderwriting;

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
        insertIf(doInsert, contacts);
        return contacts;
    }

    /** Single Contact. @param accountId Parent Account (nullable). @param doInsert Insert when true. @return The Contact. */
    public static Contact createContact(Id accountId, Boolean doInsert) {
        return createContacts(1, accountId, doInsert)[0];
    }

    /**
     * Contacts flagged Is_Broker__c = true. REQUIRED for any Broker__c lookup:
     * Broker_Assignment__c.Broker__c and Lease_Inquiry__c.Broker__c both carry an
     * active, non-optional lookup filter on Contact.Is_Broker__c.
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
        insertIf(doInsert, brokers);
        return brokers;
    }

    /** Single broker Contact. @param accountId Parent Account (nullable). @param doInsert Insert when true. @return The broker Contact. */
    public static Contact createBrokerContact(Id accountId, Boolean doInsert) {
        return createBrokerContacts(1, accountId, doInsert)[0];
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
                Deal_Type__c = 'Commercial',
                Asset_Type__c = 'Retail',
                Property_Address__c = i + ' Test Street, Houston, TX',
                Guidance_Price__c = 1000000 + (i * 1000),
                Guidance_Cap_Rate__c = 6.5
            ));
        }
        insertIf(doInsert, leads);
        return leads;
    }

    /** Single Lead. @param doInsert Insert when true. @return The Lead. */
    public static Lead createLead(Boolean doInsert) {
        return createLeads(1, doInsert)[0];
    }

    /**
     * Opportunities at StageName 'New' — valid in BOTH the Land and Commercial
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
                Deal_Type__c = 'Commercial',
                // Opportunity.Asset_Type__c uses 'Retail Strip'; Lead/Property use 'Retail'.
                Asset_Type__c = 'Retail Strip',
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
     * the only stage present in both the Land and Commercial business processes;
     * a stage outside the record type's process fails on insert.
     * @param count                  Number of Opportunities.
     * @param recordTypeDeveloperName 'Land' or 'Commercial'.
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
                'Unknown Opportunity record type: ' + recordTypeDeveloperName + '. Expected Land or Commercial.'
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

    /**
     * Day-0 checklist Tasks for a Transaction. These attach via Transaction_Deal__c
     * (NOT WhatId) so they stay off the Activity timeline, and they fire
     * TaskRollupTrigger.
     *
     * NOTE: this method does not cap `count`. TaskFanoutService fans out ~75 Tasks
     * per Transaction; 251 Transactions x 75 = 18,825 rows against the 10,000
     * DML-rows limit. That break is a genuine Phase 7 finding — the factory
     * deliberately does not paper over it by shrinking the fan-out.
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
                Target_Sale_Price__c = 1200000 + (i * 1000),
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

    /**
     * NDAs. Remember OpportunityReviewTrigger.ensureNda already creates one NDA
     * per Opportunity on insert — these are additional.
     * @param count         Number of NDAs.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return NDAs.
     */
    public static List<NDA__c> createNdas(Integer count, Id opportunityId, Boolean doInsert) {
        requirePositive(count);
        List<NDA__c> ndas = new List<NDA__c>();
        for (Integer i = 0; i < count; i++) {
            ndas.add(new NDA__c(
                Opportunity__c = opportunityId,
                Status__c = 'Pending',
                Counterparty_Name__c = 'Test Counterparty ' + i,
                Method__c = 'DocuSign',
                Date_Sent__c = Date.today(),
                Never_Expires__c = false,
                NDA_Expiry_Date__c = Date.today().addYears(1)
            ));
        }
        insertIf(doInsert, ndas);
        return ndas;
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

    /**
     * @param count         Number of LOIs.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return LOIs at stage 'Draft'.
     */
    public static List<LOI__c> createLois(Integer count, Id opportunityId, Boolean doInsert) {
        requirePositive(count);
        List<LOI__c> lois = new List<LOI__c>();
        for (Integer i = 0; i < count; i++) {
            lois.add(new LOI__c(
                Opportunity__c = opportunityId,
                Stage__c = 'Draft',
                Offer_Price__c = 1000000 + (i * 1000),
                Offer_Cap_Rate__c = 6.5,
                Earnest_Money__c = 50000,
                Due_Diligence_Days__c = 45,
                Closing_Period_Days__c = 30,
                NOI__c = 65000 + (i * 100),
                Square_Footage__c = 10000 + (i * 100),
                Submitted_Date__c = Date.today(),
                Title_Company__c = 'Test Title Co'
            ));
        }
        insertIf(doInsert, lois);
        return lois;
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
                Cash_on_Cash_Return__c = 8,
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

    /**
     * @param count         Number of Contract Reviews.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return Contract Reviews at stage 'PSA Drafting'.
     */
    public static List<Contract_Review__c> createContractReviews(Integer count, Id opportunityId, Boolean doInsert) {
        requirePositive(count);
        List<Contract_Review__c> reviews = new List<Contract_Review__c>();
        for (Integer i = 0; i < count; i++) {
            reviews.add(new Contract_Review__c(
                Opportunity__c = opportunityId,
                Stage__c = 'PSA Drafting',
                Contract_Value__c = 1000000 + (i * 1000),
                PSA_Date__c = Date.today()
            ));
        }
        insertIf(doInsert, reviews);
        return reviews;
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
        List<Deal_Message__c> messages = new List<Deal_Message__c>();
        for (Integer i = 0; i < count; i++) {
            messages.add(new Deal_Message__c(
                Direction__c = 'Internal',
                Method__c = 'Note',
                Entry_Date__c = System.now(), // DateTime, not Date
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
                // Wire_Approval_Due__c is a CHECKBOX despite the date-sounding name.
                Wire_Approval_Due__c = false
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
    // DISPOSITIONS
    // NOTE: Wire__c parents to Disposition__c, NOT Transaction__c — the org has no
    // Wire__c -> Transaction__c relationship. Transaction__c.Wire_Open_Risks__c is
    // computed from checklist Tasks, not from Wire__c.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count           Number of Dispositions.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Dispositions at stage 'Disposition Readiness'.
     */
    public static List<Disposition__c> createDispositions(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
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
        insertIf(doInsert, dispositions);
        return dispositions;
    }

    /** Dispositions under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Dispositions. */
    public static List<Disposition__c> createDispositions(Integer count, Boolean doInsert) {
        return createDispositions(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Disposition. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The Disposition. */
    public static Disposition__c createDisposition(Id propertyAssetId, Boolean doInsert) {
        return createDispositions(1, propertyAssetId, doInsert)[0];
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
     * @param count         Number of BOV Submissions.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return BOV Submissions at status 'Backup'.
     */
    public static List<BOV_Submission__c> createBovSubmissions(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<BOV_Submission__c> submissions = new List<BOV_Submission__c>();
        for (Integer i = 0; i < count; i++) {
            submissions.add(new BOV_Submission__c(
                Disposition__c = dispositionId,
                Submission_Status__c = 'Backup',
                Broker_Firm__c = 'Test Brokerage ' + i,
                Contact_Name__c = 'Test Broker ' + i,
                BOV_Amount__c = 1200000 + (i * 1000),
                Cap_Rate__c = 6.25,
                Commission_Rate__c = 2.5,
                Days_To_Market__c = 30,
                BOV_Score__c = 80,
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
     * Wires. Parents to Disposition__c — there is no Wire__c -> Transaction__c
     * relationship in this org.
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
     * @return Onboardings at stage 'Property Set up'.
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
                // Base_Rent__c / Lease_Term__c / Free_Rent__c / TI_Allowance__c are TEXT,
                // not Currency/Number — see the type-inversion note in the class header.
                Base_Rent__c = String.valueOf(5000 + (i * 10)),
                Lease_Term__c = '60',
                Free_Rent__c = '2',
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
        List<Lease_Activity__c> activities = new List<Lease_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Lease_Activity__c(
                Lease_Inquiry__c = leaseInquiryId,
                Ball_In_Court__c = 'Landlord',
                Entry_Date__c = System.now(), // DateTime, not Date
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
                Renewal_Option__c = true,
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
        List<Renewal_Activity__c> activities = new List<Renewal_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Renewal_Activity__c(
                Lease_Renewal__c = leaseRenewalId,
                Method__c = 'Call',
                Entry_Date__c = System.now(), // DateTime, not Date
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
     * Work orders. BOTH Subject__c and Reported_Date__c are schema-required;
     * Reported_Date__c anchors every SLA formula, so it is set deterministically
     * rather than relying on CreatedDate. Ownership uses Owner_User__c (a lookup),
     * NOT the standard OwnerId. Unit_Label__c here is a TEXT field (may hold
     * non-unit values such as 'Common' - it was never a unit reference).
     * @param count           Number of Work Orders.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Work Orders at status 'New'.
     */
    public static List<Work_Order__c> createWorkOrders(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Work_Order__c> workOrders = new List<Work_Order__c>();
        for (Integer i = 0; i < count; i++) {
            workOrders.add(new Work_Order__c(
                Property_Asset__c = propertyAssetId,
                Subject__c = 'Test Work Order ' + i,
                Reported_Date__c = System.now().addHours(-1),
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
     * @param count           Number of Work Orders.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param reportedDate    Value for Reported_Date__c (SLA anchor).
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
            throw new TestDataFactoryException('reportedDate is required; Work_Order__c.Reported_Date__c anchors all SLA math.');
        }
        List<Work_Order__c> workOrders = createWorkOrders(count, propertyAssetId, false);
        for (Work_Order__c workOrder : workOrders) {
            workOrder.Reported_Date__c = reportedDate;
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
        List<Work_Order_Activity__c> activities = new List<Work_Order_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Work_Order_Activity__c(
                Work_Order__c = workOrderId,
                Kind__c = 'Sync',
                Entry_Date__c = System.now(),
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
}
