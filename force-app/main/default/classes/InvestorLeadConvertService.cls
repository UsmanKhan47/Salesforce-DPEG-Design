/**
 * InvestorLeadConvertService — the Investor Relations lead conversion, exposed to Flow.
 *
 * Backs the "Investor Converted" quick action: quick action -> Screen Flow -> this Apex Action.
 *
 * 🔴 THERE IS NO CONTACT BEFORE CONVERSION — THE CONVERSION CREATES IT (redesigned 2026-08-12).
 * This class used to convert onto a Contact an earlier "Create Profile" step had already made.
 * That premise is gone: creating a standalone Contact ahead of conversion tripped
 * DUPLICATES_DETECTED, because the org's Contact duplicate rule matches a new Contact against OPEN
 * LEADS and therefore always matched the very Lead being worked. Letting Database.convertLead mint
 * the Contact sidesteps it entirely — conversion is a built-in operation the duplicate rule does
 * not block.
 *
 * Per Lead:
 *   1. insert a temporary Account, stamped Investor_Entity (describe-resolved, never a hardcoded Id)
 *   2. Database.convertLead(setLeadId + setAccountId + setDoNotCreateOpportunity(true)) — and
 *      deliberately NO setContactId, which is what makes the platform create the Contact
 *   3. read LeadConvertResult.getContactId()
 *   4. ONE update on that Contact: RecordTypeId = Contact `Investor`, AccountId = null
 *   5. delete the temporary Account — only ever those whose step-4 detach is CONFIRMED successful
 *
 * 🔴 STEP 4 MUST PRECEDE STEP 5, AND THIS IS NOT A STYLE PREFERENCE. Until it is detached the new
 * Contact is a CHILD of the temporary Account, and deleting an Account cascades into its Contacts —
 * deleting first destroys the investor Contact this action just created. Enforced structurally
 * (detachContacts is called before deleteTempAccounts) and defensively (an Account Id only enters
 * the delete set once its Contact's detach save-result is successful).
 *
 * A null AccountId together with the `Investor` record type is accepted by the Contact validation
 * rule Record_Type_Matches_Account, so both writes fit in one statement.
 *
 * 🔴 setDoNotCreateOpportunity(true) WORKS HERE. The historical UNKNOWN_EXCEPTION it produced came
 * from the `Lead_Approved_Notify` record-triggered Flow binding a REQUIRED Apex input to
 * $Record.ConvertedOpportunityId; that flow now null-guards the binding. UNKNOWN_EXCEPTION from
 * Database.convertLead is ALWAYS a wrapper for a downstream trigger/rule/flow failure — it never
 * means "the platform does not support this option", and the real cause appears only in the raw
 * debug log.
 *
 * 🔴 THE Investor_Onboarding GUARD IN LeadConvertService STAYS — DO NOT DELETE IT AS REDUNDANT.
 * It is the only INTENTIONAL protection stopping the acquisitions cascade from stamping this
 * investor Contact as `Broker` (stampConvertedPartyRecordTypes, the one effect that survives) and
 * building a Property__c. The null-ConvertedOpportunityId early return only happens to catch IR
 * conversions today.
 *
 * ⚠ OpportunityReviewTriggerHandler.bypassDealTreeCreation is NOT set here: no Opportunity is
 * created, so OpportunityReviewTrigger never fires. That seam remains declared for other callers.
 *
 * ── GOVERNOR SHAPE IS A CONTRACT: 1 SOQL / 3 DML + 1 convertLead, CONSTANT IN LEAD COUNT ────────
 *   SOQL 1 — InvestorLeadConvertSelector.selectByIds   (the Leads)
 *   DML  1 — Database.insert(tempAccounts, false)      (one bulk insert)
 *   ---- Database.convertLead(conversions, false)      (one call, partial success)
 *   DML  2 — Database.update(detachments, false)       (one bulk detach + record-type stamp)
 *   DML  3 — Database.delete(doomedAccounts, false)    (one bulk delete)
 * Every statement is isEmpty()-guarded and every one is allOrNone = false, so one bad Lead can
 * never roll back another Lead's conversion or — worse — another Lead's CLEANUP. Cleanup runs on
 * the failure path too: it is the unconditional next statement after the conversion attempt, not a
 * catch block. Record-type resolution is a memoized DESCRIBE and costs no SOQL.
 *
 * ── FAILURE HANDLING ────────────────────────────────────────────────────────────────────────────
 * Nothing here throws into the Flow's fault path — a fault screen cannot say WHICH Lead failed.
 * Every outcome is reported on its own index-parallel Result. Refusals that touch no database at
 * all: blank Lead Id, an Id that is not a Lead, Lead not visible, Lead already converted.
 *
 * ⚠ RECORD-TYPE VISIBILITY IS A DEPLOY GATE. Both stamps degrade to "leave it unset" when the
 * record type is absent or not available to the running user, and profiles are .forceignore'd, so
 * no file-based check can see it. Verify as the real IR persona; an administrator smoke test proves
 * nothing.
 * ⚠ The Lead's ConvertedAccountId points at the deleted temporary Account; the durable link is
 * ConvertedContactId. ConvertedOpportunityId is null.
 *
 * Layer: Service. Zero inline SOQL — the read goes through InvestorLeadConvertSelector.
 *
 * @see force-app/main/default/classes/InvestorLeadConvertSelector.cls
 * @see force-app/main/default/classes/LeadConvertService.cls (the acquisitions chain this avoids)
 * @see .claude/rules/invocable-rule.md
 */
public with sharing class InvestorLeadConvertService {

    /**
     * The org's converted LeadStatus. Verified against this org's Lead Status value set
     * (New, Under Review, Create Profile, Converted) — only 'Converted' is flagged converted=true.
     * Passing any other value to setConvertedStatus throws.
     */
    public static final String CONVERTED_STATUS = 'Converted';

    /**
     * Name prefix for the throwaway Account. The full name is "<prefix> <leadId>", which makes an
     * orphan (should one survive a catastrophic failure) self-identifying: it names the Lead it
     * belongs to, and distinct names keep N simultaneous temp Accounts from looking like N
     * duplicates of one record to any Account duplicate rule.
     */
    public static final String TEMP_ACCOUNT_NAME_PREFIX = 'IR Conversion Temp Account';

    /** Account record type stamped on the temporary Account. */
    private static final String TEMP_ACCOUNT_RECORD_TYPE = 'Investor_Entity';

    /** Contact record type stamped on the Contact the conversion creates. */
    private static final String INVESTOR_CONTACT_RECORD_TYPE = 'Investor';

    // Memoized describe results. A SEPARATE "resolved" flag because null is a LEGITIMATE answer
    // (record type absent, or not available to this user) rather than a cache miss — without it
    // every invocation in such an org would re-describe forever.
    private static Id tempAccountRecordTypeIdCache;
    private static Boolean tempAccountRecordTypeResolved = false;
    private static Id investorContactRecordTypeIdCache;
    private static Boolean investorContactRecordTypeResolved = false;

    // ── Refusals (no database work attempted) ───────────────────────────────────────────────
    public static final String ERROR_NOT_PROCESSED = 'This Lead was not processed.';
    public static final String ERROR_MISSING_LEAD_ID =
        'No Lead Id was supplied to the Investor Converted action.';
    public static final String ERROR_NOT_A_LEAD_ID =
        'The Id supplied to the Investor Converted action is not a Lead Id: ';
    public static final String ERROR_LEAD_NOT_FOUND =
        'Lead not found, or not visible to you: ';
    public static final String ERROR_ALREADY_CONVERTED =
        'This Lead has already been converted: ';

    // ── Failures (database work attempted) ──────────────────────────────────────────────────
    public static final String ERROR_READ_DENIED =
        'Unable to read the Lead records. This is usually a missing permission. Details: ';
    public static final String ERROR_TEMP_ACCOUNT =
        'Could not create the temporary Account used for conversion. Details: ';
    public static final String ERROR_CONVERT = 'Lead conversion failed. Details: ';
    public static final String ERROR_UNEXPECTED =
        'The Investor Converted action failed unexpectedly. Details: ';

    // ── Warnings (the conversion outcome stands; cleanup left something behind) ─────────────
    public static final String WARNING_DETACH =
        'WARNING: the investor Contact could not be detached from the temporary Account, so the '
        + 'temporary Account was deliberately NOT deleted - deleting it would cascade-delete the '
        + 'Contact. An administrator must detach the Contact first, then delete the Account. Details: ';
    public static final String WARNING_TEMP_ACCOUNT_DELETE =
        'WARNING: the temporary Account could not be deleted and must be removed manually. '
        + 'The investor Contact is safe and is no longer attached to it. Details: ';

    /**
     * Converts each supplied Investor Relations Lead, letting the conversion CREATE the investor
     * Contact, then re-typing that Contact as `Investor`, detaching it, and deleting the temporary
     * Account. Leaves NO Opportunity and no temporary Account behind. See the class header.
     *
     * Bulk-safe and index-parallel: results[i] always describes requests[i], for every outcome
     * including refusals. One SOQL and at most three DML statements of its own, plus one
     * Database.convertLead call, regardless of how many Leads are supplied.
     *
     * This method does not throw. Every failure is reported on the corresponding Result so the
     * Screen Flow can branch on `success` and display `errorMessage`.
     *
     * @param requests One entry per Lead to convert. A null or empty list returns an empty list.
     * @return One Result per Request, in the same order (never null, never shorter than the input).
     * @example
     * InvestorLeadConvertService.Request req = new InvestorLeadConvertService.Request();
     * req.leadId = leadId;
     * List<InvestorLeadConvertService.Result> results =
     *     InvestorLeadConvertService.convertInvestorLeads(
     *         new List<InvestorLeadConvertService.Request>{ req });
     */
    @InvocableMethod(
        label='Convert Investor Lead'
        description='Converts an Investor Relations Lead. The conversion itself creates the investor Contact (record type Investor, no Account) and no Opportunity; the temporary Account used to make it legal is deleted.'
        category='Investor Relations'
    )
    public static List<Result> convertInvestorLeads(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }
        // Seed one Result per Request FIRST, so the list is index-parallel and fully populated no
        // matter where processing stops. No caller ever receives a null or a short list.
        for (Integer i = 0; i < requests.size(); i++) {
            Result seeded = new Result();
            seeded.success = false;
            seeded.errorMessage = ERROR_NOT_PROCESSED;
            results.add(seeded);
        }
        try {
            process(requests, results);
        } catch (Exception e) {
            // Backstop only. Every expected failure is handled in typed form inside process().
            markUnprocessed(results, ERROR_UNEXPECTED + e.getMessage());
        }
        return results;
    }

    // ─── Orchestration ───────────────────────────────────────────────────────────────────────

    /**
     * The five-step sequence from the class header. Each phase narrows the working set: a Lead that
     * fails a phase has its Result written and drops out, and later phases never see it.
     */
    private static void process(List<Request> requests, List<Result> results) {
        Map<Id, Lead> leadsById;
        try {
            leadsById = new Map<Id, Lead>(
                InvestorLeadConvertSelector.selectByIds(collectLeadIds(requests))  // SOQL 1
            );
        } catch (System.QueryException e) {
            // USER_MODE throws rather than degrading, and on this user-initiated path that is the
            // intended behaviour. Nothing has been written yet, so there is no cleanup to perform.
            failAll(results, ERROR_READ_DENIED + e.getMessage());
            return;
        }

        // Step 0 — validate and refuse. Nothing is written in this phase.
        List<Work> works = validate(requests, results, leadsById);
        if (works.isEmpty()) {
            return;
        }

        // Step 1 — one bulk insert of the temporary Accounts.
        works = createTempAccounts(works, results);
        if (works.isEmpty()) {
            return;
        }

        // Every Work here owns a temp Account, so this map resolves any temp Account Id back to the
        // Result that should carry a cleanup warning about it.
        Map<Id, Work> workByTempAccountId = new Map<Id, Work>();
        for (Work work : works) {
            workByTempAccountId.put(work.tempAccountId, work);
        }

        // Steps 2 and 3 — the conversion, which CREATES the Contact. Never throws out of this call.
        // A Lead whose conversion failed has no Contact, so its temp Account is childless and is
        // handed straight to the delete set.
        Set<Id> deletableAccountIds = new Set<Id>();
        List<Work> converted = convertLeads(works, results, deletableAccountIds);

        // ══ Steps 4 and 5 — CLEANUP. RUNS ON THE SUCCESS PATH AND THE FAILURE PATH ALIKE. ══
        // 🔴 THE ORDER OF THESE TWO STATEMENTS IS NOT NEGOTIABLE. The new Contact is currently a
        // CHILD of the temporary Account; deleting an Account cascades into its Contacts, so
        // deleting first would DELETE THE INVESTOR'S CONTACT. Detach (and re-type) first; only then
        // delete, and only those Accounts whose detach was CONFIRMED successful.
        detachContacts(converted, results, deletableAccountIds);
        deleteTempAccounts(deletableAccountIds, workByTempAccountId, results);
    }

    // ─── Step 0: validate ────────────────────────────────────────────────────────────────────

    /** Lead-typed Ids from the incoming requests; anything else is refused later, by index. */
    private static Set<Id> collectLeadIds(List<Request> requests) {
        Set<Id> leadIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null && isLeadId(request.leadId)) {
                leadIds.add(request.leadId);
            }
        }
        return leadIds;
    }

    /**
     * Writes a refusal onto every Result that cannot proceed and returns the Work items that can.
     * No database work happens in this phase, so a refusal here needs no cleanup.
     */
    private static List<Work> validate(
        List<Request> requests,
        List<Result> results,
        Map<Id, Lead> leadsById
    ) {
        List<Work> works = new List<Work>();

        for (Integer i = 0; i < requests.size(); i++) {
            Request request = requests[i];
            Id leadId = (request == null) ? null : request.leadId;

            if (leadId == null) {
                fail(results[i], ERROR_MISSING_LEAD_ID);
                continue;
            }
            if (!isLeadId(leadId)) {
                // Refused rather than queried: a foreign Id inside `WHERE Id IN :leadIds` raises a
                // QueryException that would take down the whole batch over one bad input.
                fail(results[i], ERROR_NOT_A_LEAD_ID + leadId);
                continue;
            }
            Lead lead = leadsById.get(leadId);
            if (lead == null) {
                fail(results[i], ERROR_LEAD_NOT_FOUND + leadId);
                continue;
            }
            if (lead.IsConverted == true) {
                fail(results[i], ERROR_ALREADY_CONVERTED + leadLabel(lead));
                continue;
            }

            Work work = new Work();
            work.index = i;
            work.leadId = leadId;
            works.add(work);
        }
        return works;
    }

    // ─── Step 1: temporary Accounts ──────────────────────────────────────────────────────────

    /**
     * A record type Id resolved by DEVELOPER NAME, or null when the record type is absent from this
     * org or is not available to the running user. A DESCRIBE, so it costs no SOQL.
     *
     * 🔴 NEVER A HARDCODED ID — resolved by DeveloperName so this repo deploys to any org.
     * ⚠ isAvailable()-guarded: stamping a record type the running user cannot use fails the DML
     * outright, so an unavailable record type must degrade to "leave it unset" rather than take the
     * whole conversion down.
     */
    private static Id recordTypeIdFor(Schema.SObjectType sobjectType, String developerName) {
        // DEFERRED: record-type info does not need the child-relationship graph, and loading it
        // eagerly is a measurable cost on standard objects.
        Schema.RecordTypeInfo info = sobjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** Memoized Investor_Entity Account record type Id (null is a legitimate answer). */
    private static Id tempAccountRecordTypeId() {
        if (!tempAccountRecordTypeResolved) {
            tempAccountRecordTypeIdCache =
                recordTypeIdFor(Account.SObjectType, TEMP_ACCOUNT_RECORD_TYPE);
            tempAccountRecordTypeResolved = true;
        }
        return tempAccountRecordTypeIdCache;
    }

    /** Memoized Investor Contact record type Id (null is a legitimate answer). */
    private static Id investorContactRecordTypeId() {
        if (!investorContactRecordTypeResolved) {
            investorContactRecordTypeIdCache =
                recordTypeIdFor(Contact.SObjectType, INVESTOR_CONTACT_RECORD_TYPE);
            investorContactRecordTypeResolved = true;
        }
        return investorContactRecordTypeIdCache;
    }

    /**
     * One bulk insert. Returns only the Work items that now own a temporary Account.
     *
     * The Account exists because Lead.Company is nillable here and Person Accounts are enabled: a
     * blank-Company Lead left to convert on its own would mint a PERSON Account. Naming and typing
     * the target Account removes that path entirely.
     */
    private static List<Work> createTempAccounts(List<Work> works, List<Result> results) {
        Id tempAccountRecordTypeId = tempAccountRecordTypeId();
        List<Account> tempAccounts = new List<Account>();
        for (Work work : works) {
            Account tempAccount = new Account(Name = TEMP_ACCOUNT_NAME_PREFIX + ' ' + work.leadId);
            if (tempAccountRecordTypeId != null) {
                tempAccount.RecordTypeId = tempAccountRecordTypeId;
            }
            tempAccounts.add(tempAccount);
        }
        List<Database.SaveResult> saveResults = Database.insert(tempAccounts, false);   // DML 1

        List<Work> live = new List<Work>();
        for (Integer i = 0; i < works.size(); i++) {
            Work work = works[i];
            if (saveResults[i].isSuccess()) {
                work.tempAccountId = saveResults[i].getId();
                results[work.index].accountId = work.tempAccountId;
                live.add(work);
            } else {
                fail(results[work.index], ERROR_TEMP_ACCOUNT + firstError(saveResults[i].getErrors()));
            }
        }
        return live;
    }

    // ─── Steps 2 and 3: convert, and read the Contact the conversion created ─────────────────

    /**
     * The conversion itself: a temporary Account, NO Opportunity, and — the point of the redesign —
     * NO setContactId, so the platform CREATES the Contact from the Lead's own name/email/phone.
     * Creating that Contact ourselves beforehand is what tripped the duplicate rule (class header).
     *
     * Deliberately swallows any exception from Database.convertLead and converts it into per-Lead
     * messages: a rethrow would leave every temporary Account in this batch orphaned, because the
     * caller's cleanup statements would never run.
     *
     * @return Only the Work items that converted and carry a Contact Id. A Lead that did NOT
     *         convert has no Contact, so its temporary Account is childless and is added to
     *         deletableAccountIds here rather than waiting for a detach with nothing to detach.
     */
    private static List<Work> convertLeads(
        List<Work> works,
        List<Result> results,
        Set<Id> deletableAccountIds
    ) {
        List<Work> converted = new List<Work>();
        if (works.isEmpty()) {
            return converted;
        }
        List<Database.LeadConvert> conversions = new List<Database.LeadConvert>();
        for (Work work : works) {
            Database.LeadConvert conversion = new Database.LeadConvert();
            conversion.setLeadId(work.leadId);
            // The Account is supplied; the CONTACT deliberately is not. setContactId is what would
            // reuse a pre-existing Contact, and creating one to reuse is exactly what the org's
            // duplicate rule refuses.
            conversion.setAccountId(work.tempAccountId);
            // 🔴 THE NO-OPPORTUNITY RULE, ENFORCED AT SOURCE. Nothing downstream has to find or
            // delete an Opportunity because none is ever created, which also keeps the whole
            // acquisitions deal-tree cascade out of this transaction.
            conversion.setDoNotCreateOpportunity(true);
            conversion.setConvertedStatus(CONVERTED_STATUS);
            conversions.add(conversion);
        }

        List<Database.LeadConvertResult> convertResults;
        try {
            convertResults = Database.convertLead(conversions, false);
        } catch (Exception e) {
            for (Work work : works) {
                fail(results[work.index], ERROR_CONVERT + e.getMessage());
                deletableAccountIds.add(work.tempAccountId);
            }
            return converted;
        }

        for (Integer i = 0; i < works.size(); i++) {
            Work work = works[i];
            Database.LeadConvertResult convertResult = convertResults[i];
            if (convertResult.isSuccess()) {
                work.contactId = convertResult.getContactId();
                results[work.index].success = true;
                results[work.index].errorMessage = null;
                results[work.index].contactId = work.contactId;
                results[work.index].accountId = convertResult.getAccountId();
                converted.add(work);
                // ⚠ convertResult.getOpportunityId() is deliberately NOT read. It is null by
                // construction (setDoNotCreateOpportunity), and reading it into state would invite
                // the next reader to re-add a delete step for a record that does not exist.
            } else {
                fail(results[work.index], ERROR_CONVERT + firstError(convertResult.getErrors()));
                deletableAccountIds.add(work.tempAccountId);
            }
        }
        return converted;
    }

    // ─── Step 4: re-type and detach (MUST run before step 5) ─────────────────────────────────

    /**
     * 🔴 STEP 4 OF 5 — THIS MUST COMPLETE BEFORE deleteTempAccounts RUNS. The Contact the conversion
     * just created is a CHILD of the temporary Account; deleting an Account cascades into its
     * Contacts, so deleting before this detach would DELETE THE INVESTOR'S CONTACT.
     *
     * One statement does both writes: RecordTypeId = Contact `Investor` and AccountId = null. That
     * pairing is accepted by the Record_Type_Matches_Account validation rule, which only fires when
     * the Contact's Account HAS a record type that is not Investor_Entity.
     *
     * A temporary Account Id is added to deletableAccountIds ONLY when its Contact's detach is
     * confirmed successful. A failed detach therefore deliberately STRANDS its temporary Account:
     * an orphan Account an administrator can clean up is an inconvenience, a cascade-deleted
     * investor Contact is data loss. `success` is left alone — the conversion genuinely happened,
     * and reporting failure would send the user back to retry a Lead that is already converted.
     */
    private static void detachContacts(
        List<Work> works,
        List<Result> results,
        Set<Id> deletableAccountIds
    ) {
        if (works.isEmpty()) {
            return;
        }
        Id investorRecordTypeId = investorContactRecordTypeId();
        List<Contact> detachments = new List<Contact>();
        for (Work work : works) {
            Contact detachment = new Contact(Id = work.contactId, AccountId = null);
            if (investorRecordTypeId != null) {
                detachment.RecordTypeId = investorRecordTypeId;
            }
            detachments.add(detachment);
        }
        List<Database.SaveResult> saveResults = Database.update(detachments, false);   // DML 2

        for (Integer i = 0; i < works.size(); i++) {
            Work work = works[i];
            if (saveResults[i].isSuccess()) {
                deletableAccountIds.add(work.tempAccountId);
            } else {
                warn(results[work.index], WARNING_DETACH + firstError(saveResults[i].getErrors()));
            }
        }
    }

    // ─── Step 5: delete the temporary Accounts ───────────────────────────────────────────────

    /**
     * 🔴 STEP 5 OF 5 — ONLY EVER CALLED AFTER detachContacts. Every Id in deletableAccountIds has
     * been proven childless: either its Lead never converted (so no Contact was created) or its
     * Contact's detach was confirmed successful. That invariant is what makes this delete safe;
     * calling this method with an unvetted Id set would cascade-delete investor Contacts.
     *
     * A delete failure is a warning, never a failure of the conversion — the Contact is already
     * safe by this point, and the residue is one empty Account named after its Lead.
     */
    private static void deleteTempAccounts(
        Set<Id> deletableAccountIds,
        Map<Id, Work> workByTempAccountId,
        List<Result> results
    ) {
        if (deletableAccountIds.isEmpty()) {
            return;
        }
        List<Id> accountIds = new List<Id>(deletableAccountIds);
        List<Account> doomedAccounts = new List<Account>();
        for (Id accountId : accountIds) {
            doomedAccounts.add(new Account(Id = accountId));
        }
        List<Database.DeleteResult> deleteResults = Database.delete(doomedAccounts, false);  // DML 3

        for (Integer i = 0; i < accountIds.size(); i++) {
            if (deleteResults[i].isSuccess()) {
                continue;
            }
            Work work = workByTempAccountId.get(accountIds[i]);
            if (work != null) {
                warn(
                    results[work.index],
                    WARNING_TEMP_ACCOUNT_DELETE + firstError(deleteResults[i].getErrors())
                );
            }
        }
    }

    // ─── Small helpers ───────────────────────────────────────────────────────────────────────

    /** True when the Id actually addresses a Lead — guards the selector's `Id IN` bind. */
    private static Boolean isLeadId(Id value) {
        return value != null && value.getSObjectType() == Lead.SObjectType;
    }

    /** Marks one Result as failed with a specific, user-actionable message. */
    private static void fail(Result result, String message) {
        result.success = false;
        result.errorMessage = message;
    }

    /**
     * Appends a cleanup warning WITHOUT changing `success`. A conversion that happened, happened;
     * downgrading it because the throwaway Account lingered would tell the user to retry a Lead
     * that is already converted.
     */
    private static void warn(Result result, String warning) {
        result.errorMessage = String.isBlank(result.errorMessage)
            ? warning
            : result.errorMessage + ' ' + warning;
    }

    /** Fails every Result with one message — used when the read phase itself is denied. */
    private static void failAll(List<Result> results, String message) {
        for (Result result : results) {
            fail(result, message);
        }
    }

    /** Replaces the seeded "not processed" message on anything the backstop catch interrupted. */
    private static void markUnprocessed(List<Result> results, String message) {
        for (Result result : results) {
            if (result.success != true && ERROR_NOT_PROCESSED.equals(result.errorMessage)) {
                result.errorMessage = message;
            }
        }
    }

    /** The first platform error as "STATUS_CODE: message", or a stable fallback. */
    private static String firstError(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'Unknown error.';
        }
        Database.Error error = errors[0];
        return String.valueOf(error.getStatusCode()) + ': ' + error.getMessage();
    }

    /** A human-readable identifier for a Lead, for refusal messages. */
    private static String leadLabel(Lead lead) {
        List<String> nameParts = new List<String>();
        if (String.isNotBlank(lead.FirstName)) {
            nameParts.add(lead.FirstName);
        }
        if (String.isNotBlank(lead.LastName)) {
            nameParts.add(lead.LastName);
        }
        String name = nameParts.isEmpty() ? String.valueOf(lead.Id) : String.join(nameParts, ' ');
        String status = String.isBlank(lead.Status) ? 'unknown' : lead.Status;
        return name + ' (Status: ' + status + ')';
    }

    // ─── Internal working state ──────────────────────────────────────────────────────────────

    /**
     * One in-flight conversion. Carries the input index so any phase can write its outcome back to
     * the correct Result without re-deriving position.
     *
     * ⚠ contactId is populated by the CONVERSION, not before it — there is no pre-existing Contact
     * in this design, so there is nothing to look up and no original AccountId to restore.
     */
    private class Work {
        private Integer index;
        private Id leadId;
        private Id tempAccountId;
        private Id contactId;
    }

    // ─── Flow contract ───────────────────────────────────────────────────────────────────────

    /** Input from the calling Screen Flow: the Lead to convert. */
    public class Request {
        @InvocableVariable(
            label='Lead Id'
            description='The Investor Relations Lead to convert. The conversion creates its Contact.'
            required=true
        )
        public Id leadId;
    }

    /**
     * Output to the calling Screen Flow, one per Request and in the same order. Branch on
     * `success`; display `errorMessage`.
     */
    public class Result {
        @InvocableVariable(
            label='Success'
            description='True when the Lead was converted and its investor Contact created.'
        )
        public Boolean success;

        @InvocableVariable(
            label='Error Message'
            description='Why the conversion was refused or failed. May also carry a cleanup warning on an otherwise successful conversion.'
        )
        public String errorMessage;

        @InvocableVariable(
            label='Contact Id'
            description='The investor Contact created by the conversion, re-typed as Investor and detached from any Account.'
        )
        public Id contactId;

        @InvocableVariable(
            label='Account Id'
            description='The TEMPORARY Account used to make the conversion legal. It is deleted before this action returns, so do not navigate to it.'
        )
        public Id accountId;
    }
}
