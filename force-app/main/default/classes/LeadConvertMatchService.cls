/**
 * LeadConvertMatchService — decides WHAT a lead conversion should attach to.
 *
 * ── THE THREE SIMILARLY-NAMED CLASSES (read this before editing any of them) ──────────────
 *   • LeadConvertActionService  — RUNS Database.convertLead (the only place in the app that does).
 *   • LeadConvertMatchService   — THIS CLASS. Decides what that conversion attaches to. Runs
 *                                 BEFORE the convert, reads only, returns a decision.
 *   • LeadConvertService        — STAMPS the new Opportunity and creates the Property__c. Runs
 *                                 AFTER the convert, via LeadConvertTrigger.
 *
 * ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────
 * Triggering incident, 2026-08-02 on `usman-dpeg`, live: converting the Lead
 * *Usman Khan / usmankhan-96@hotmail.com / "Unknown - Via Email"* failed with
 * `DUPLICATES_DETECTED, Duplicate Alert: []`. That broker already existed as a Contact, so
 * standard conversion tried to mint a SECOND Contact for the same person and the org's active
 * Contact duplicate rule blocked the whole conversion. Before this class, convert() performed
 * zero reads and always asked the platform to create fresh records.
 *
 * This class answers, for a batch of Leads at once: does this broker already exist as a Contact,
 * and/or does their firm already exist as an Account? The caller turns a hit into
 * setContactId / setAccountId so the conversion ATTACHES instead of duplicating.
 *
 * ── D1a — EMAIL IS THE ONLY CONTACT MATCH KEY. NAME IS NEITHER A REQUIREMENT NOR A WIDENER ──
 * A Contact matches when Contact.Email = Lead.Email. The person NAME is deliberately unused:
 *   • Not as a REQUIREMENT, because the name is LLM-extracted from a forwarded signature block
 *     and is the least stable value on these Leads — "Usman Khan", "Usman A. Khan" and
 *     "Khan, Usman" are all reachable for one broker. Requiring a name match would make this
 *     feature miss exactly the case it exists for and mint the duplicate anyway.
 *   • Not as a WIDENER (i.e. matching on name when the email differs), because that would fuse
 *     two different "John Smith" brokers at two different firms into one Contact and attach a
 *     deal to the wrong person.
 * The asymmetry is the whole argument: a MISSED match creates a duplicate, which a human can
 * merge; a WRONG match mis-attributes a deal to another broker, which the user cannot undo from
 * a headless quick action and which is the precise opposite of broker protection. PREFER THE
 * RECOVERABLE FAILURE. Email is also what the rest of this module already treats as broker
 * identity (Competing_Broker_Submission__c.Broker_Email__c, selectRecentByBrokerEmail,
 * GuestReads.selectBrokerPriorityByEmailSystem).
 *
 * ── D1b — THE PLACEHOLDER COMPANY MUST NOT ACCOUNT-MATCH (the crux) ───────────────────────
 * Account-name matching is reachable ONLY when no Contact matched (Salesforce requires a
 * specified Contact's own Account to be the conversion target, so a Contact hit dictates the
 * Account) AND the Lead's Company is not EmailToLeadService.COMPANY_PLACEHOLDER
 * ('Unknown - Via Email').
 *
 * Bucketing every firm-unknown broker into one shared placeholder Account was rejected because
 * of BrokerFirmController.getBrokerFirm + OpportunitySelector.countByStageForAccount: that
 * sidebar aggregates EVERY Opportunity on an Account into "this firm's" submitted/won/lost deal
 * counts and names the earliest-created Contact on the Account as "the broker". Bucketing would
 * therefore put an ACTIVELY WRONG answer on a live page — every unrelated broker's deals shown as
 * one firm's, and a random other broker named as the broker — in the one module whose entire
 * purpose is broker attribution. It would also pool every firm-unknown broker's Contacts and
 * Opportunities under a single Account.
 *
 * And it buys nothing: the repeat-broker case (the incident, and the normal case) is already
 * solved by the CONTACT match, which reuses that broker's own Account. 'Unknown - Via Email' is
 * not a firm name — it is a null wearing a string — and matching records on a null value is a
 * category error. Under this rule the placeholder Account proliferates once per DISTINCT BROKER
 * (a per-broker firm stub awaiting a real name), never once per conversion.
 *
 * Where the account match does earn its keep: a NEW broker (no Contact yet) whose email carried a
 * real firm name, e.g. Company = 'Marcus & Millichap'. Their new Contact lands under the existing
 * firm Account instead of creating a second one.
 *
 * ── D1c — NO LeadSource FILTER ───────────────────────────────────────────────────────────
 * Every Lead converted through the action is matched. Duplicates are not a Broker-Protection-only
 * problem, and a LeadSource filter would give one button two different behaviours that nobody
 * could see from the UI.
 *
 * ── D2 — OLDEST WINS, DETERMINISTICALLY ──────────────────────────────────────────────────
 * Both selectors order `CreatedDate ASC, Id ASC` and this class takes the FIRST row per key.
 * Oldest, because it carries the most history and is the record a manual merge would keep as
 * master — so code and human converge on the same winner. `Id ASC` is the tiebreak because rows
 * created in one transaction share a CreatedDate; without it the pick is not a total order and
 * the target could oscillate between two records across conversions. The rule is CONVERGENT: a
 * newly created duplicate can never displace the canonical target.
 *
 * ── FAIL-SOFT — THE ONE PIECE OF BEHAVIOUR THAT IS NOT ABOUT MATCHING ─────────────────────
 * Lead.Email and Contact.Email are FLS-permissionable, and `WITH USER_MODE` THROWS rather than
 * degrading when the running user lacks read. A raw throw here would REGRESS conversion for users
 * who can convert perfectly well today — this feature would have made the app worse for them.
 * So every read is wrapped: System.QueryException => log at ERROR, set `lastRunDegraded`, and
 * return an EMPTY map.
 *
 * ⚠ BE PRECISE ABOUT THE BASELINE — a degrade is NOT "exactly what happened before". It returns
 * this MATCHER to its pre-existence behaviour, but the always-on duplicate-rule bypass
 * (LeadConvertActionService, D4) shipped in the SAME change, and it does not degrade. So for a
 * repeat broker the real before/after is:
 *   • BEFORE this change  — DUPLICATES_DETECTED, a loud terminal failure; the deal is stranded.
 *   • DEGRADED AFTER      — the conversion SUCCEEDS and silently creates a duplicate Contact.
 * A degrade therefore converts a loud failure into silent duplicate accumulation. That is still
 * the right trade (a duplicate is recoverable by merge; a stranded deal is not, and from a
 * headless quick action the user can neither merge nor override), but it is a NEW ACCEPTED COST
 * introduced here, not a return to the status quo. Its mitigations are external to this class:
 *   1. The DEPLOY-TIME FLS GATE — every convert-capable persona must hold read on BOTH Lead.Email
 *      and Contact.Email, or it degrades for them permanently. Verify as a real persona, never as
 *      an admin (FLS truth lives in the org; profiles are .forceignore'd).
 *   2. The scheduled DUPLICATE JOB, which is what actually surfaces the duplicates the bypass
 *      lets through — the bypass skips the rule's Report operation, so no DuplicateRecordSet is
 *      logged for a conversion-created duplicate.
 *
 * Degrading (rather than throwing) is still correct because matching is an OPTIMISATION OVER
 * PLATFORM DEFAULT BEHAVIOUR, not an authorization control — it guards nothing, so failing open
 * grants no access. (Contrast PropertyClaimService, which fails CLOSED because it guards a
 * commission-bearing claim.) Note this is the opposite polarity to `with sharing` below, which IS
 * a real control and is not bypassed.
 *
 * ⚠ THE THREE SELECTOR METHODS THIS CLASS CALLS MUST KEEP RETURNING Lists — never a single SObject.
 * `selectMatchKeysByIds`, `selectByEmails` and `selectByNames` all return `List<...>`, so "no rows"
 * is an empty list. If any of them is ever refactored to a single-row assignment
 * (`Contact c = [SELECT ...];`), a LEGITIMATE no-rows condition would throw QueryException, land in
 * the catch below, and be silently swallowed as a "degrade" — turning the ordinary no-match case
 * into a permanent, invisible disabling of matching. The empty-list contract is load-bearing
 * precisely BECAUSE this catch is broad.
 *
 * `lastRunDegraded` is the SEAM that makes the degrade testable — without it a silent fallback is
 * indistinguishable from "nothing matched", which is the failure mode this module has been bitten
 * by before ("fails soft => watch for silence"). It is in-transaction state for tests and
 * debugging ONLY; it is not monitoring. The production symptom of a silent degrade is duplicates
 * reappearing, which is observable in the data.
 *
 * ── LAYER / MODE ─────────────────────────────────────────────────────────────────────────
 * Layer: Service (ARCHITECTURE.md §2, .claude/rules/apex-layering-rule.md). Read + decide only:
 * ZERO DML, and every query goes through a Selector — there is no inline SOQL here.
 *
 * `with sharing` per §2. Consequence (design L2): a Contact/Account the converting user cannot
 * see will not match, so a duplicate results — silently, per the baseline note above. If that bites
 * in production the remedy is a SHARING RULE, not `without sharing` in Apex.
 *
 * BULK SHAPE IS A CONTRACT, NOT AN OPTIMISATION: exactly 3 SOQL regardless of how many Leads are
 * passed (leads' match keys, Contacts by email, Accounts by name), and fewer when a key set is
 * empty. LeadConvertMatchServiceTest pins this with a 251-Lead test asserting the query delta is
 * <= 3 — so a future change that adds one query per Lead fails there rather than in production.
 *
 * @see force-app/main/default/classes/LeadConvertActionService.cls (sole caller; runs the convert)
 * @see force-app/main/default/classes/LeadConvertService.cls (post-convert stamping, via trigger)
 * @see force-app/main/default/classes/AccountSelector.cls
 * @see force-app/main/default/classes/ContactSelector.cls (selectByEmails)
 * @see force-app/main/default/classes/LeadSelector.cls (selectMatchKeysByIds)
 * @see agent-output/design-requirements-lead-convert-matching.md
 */
public with sharing class LeadConvertMatchService {

    /**
     * True when the most recent matchForConversion call fell back to no-match because a read was
     * denied (see the fail-soft section in the class header). In-transaction, reset at the start
     * of every call. For tests and debugging only — NOT a monitoring signal.
     */
    @TestVisible
    private static Boolean lastRunDegraded = false;

    /**
     * What a single Lead's conversion should attach to.
     *
     * INVARIANT: `contactId != null` implies `accountId` is that Contact's own AccountId (never
     * null, never a different Account). Salesforce enforces the same rule —
     * Database.LeadConvert.setContactId is only valid alongside a setAccountId for that Contact's
     * Account — and ContactSelector.selectByEmails guarantees it by filtering `AccountId != null`
     * in the query. `accountId != null` with a null `contactId` is the legitimate firm-only match.
     */
    public class ConversionMatch {
        /** The existing Account to convert into, or null to let the platform create one. */
        public Id accountId;
        /** The existing Contact to convert into, or null to let the platform create one. */
        public Id contactId;
    }

    /**
     * Resolves, for each supplied Lead, the existing Contact and/or Account its conversion should
     * attach to.
     *
     * Bulk-shaped: 3 SOQL total regardless of input size (and fewer when a key set is empty), no
     * SOQL or DML inside any loop, no DML at all.
     *
     * @param leadIds the Leads about to be converted; null, empty, or all-null entries return an
     *                empty map without querying. Duplicates in the list are harmless.
     * @return a map from Lead Id to its ConversionMatch, containing an entry ONLY for Leads that
     *         matched something. A Lead absent from the map has no match and must convert exactly
     *         as it does today. Never null. Returns an EMPTY map (and sets lastRunDegraded) when a
     *         read is denied — see the class header's fail-soft section.
     * @example
     * Map<Id, LeadConvertMatchService.ConversionMatch> matches =
     *     LeadConvertMatchService.matchForConversion(leadIds);
     */
    public static Map<Id, ConversionMatch> matchForConversion(List<Id> leadIds) {
        lastRunDegraded = false;
        Map<Id, ConversionMatch> matches = new Map<Id, ConversionMatch>();

        Set<Id> uniqueLeadIds = toIdSet(leadIds);
        if (uniqueLeadIds.isEmpty()) {
            return matches;
        }

        try {
            // ── SOQL 1 of 3 — the match keys of the Leads being converted.
            List<Lead> leads = LeadSelector.selectMatchKeysByIds(uniqueLeadIds);
            if (leads.isEmpty()) {
                return matches;
            }

            Set<String> emails = new Set<String>();
            Set<String> companies = new Set<String>();
            collectMatchKeys(leads, emails, companies);

            // ── SOQL 2 and 3 of 3.
            Map<String, Contact> contactByEmail = contactsByEmail(emails);
            Map<String, Account> accountByName = accountsByName(companies);

            for (Lead l : leads) {
                ConversionMatch match = resolveMatch(l, contactByEmail, accountByName);
                if (match != null) {
                    matches.put(l.Id, match);
                }
            }
        } catch (System.QueryException e) {
            return degradeToNoMatch(e);
        }

        return matches;
    }

    /**
     * Distinct, non-null Lead Ids.
     *
     * @param leadIds the raw caller list; may be null and may contain nulls or duplicates.
     * @return a de-duplicated, null-free set; empty when the input is null/empty, in which case
     *         the caller returns before running any query.
     */
    private static Set<Id> toIdSet(List<Id> leadIds) {
        Set<Id> ids = new Set<Id>();
        if (leadIds != null) {
            ids.addAll(leadIds);
            ids.remove(null);
        }
        return ids;
    }

    /**
     * Fills the two SOQL bind sets from the Leads in ONE pass (the sets are mutated in place).
     *
     * THE D1b PLACEHOLDER EXCLUSION HAPPENS HERE AND ONLY HERE. A Company equal to
     * EmailToLeadService.COMPANY_PLACEHOLDER never enters `companies`, so it never reaches the
     * Account query, so it can never appear in the name map, so it can never match downstream.
     * That is why resolveMatch needs no second guard — do not add one, and do not remove this.
     *
     * The literal is READ FROM EmailToLeadService rather than re-typed, so the two classes cannot
     * drift apart if the placeholder is ever reworded. That cross-class read is why
     * COMPANY_PLACEHOLDER was promoted from private to public (the design's one approved scope
     * exception; visibility only, zero behaviour change).
     *
     * @param leads     the Leads whose keys to collect.
     * @param emails    OUT — trimmed, non-blank Lead emails.
     * @param companies OUT — trimmed, non-blank, non-placeholder Lead companies.
     */
    private static void collectMatchKeys(List<Lead> leads, Set<String> emails, Set<String> companies) {
        for (Lead l : leads) {
            String email = trimToNull(l.Email);
            if (email != null) {
                emails.add(email);
            }
            String company = trimToNull(l.Company);
            if (company != null && !company.equalsIgnoreCase(EmailToLeadService.COMPANY_PLACEHOLDER)) {
                companies.add(company);
            }
        }
    }

    /**
     * Existing broker Contacts keyed by normalized email, OLDEST WINS.
     *
     * The selector orders `CreatedDate ASC, Id ASC`, so first-write-wins here IS oldest-wins — no
     * second sort is needed. Orphans are already excluded by the selector's `AccountId != null`
     * filter, so every row here is a legal conversion target.
     *
     * @param emails trimmed Lead emails; empty costs no SOQL.
     * @return normalized email -> the oldest matching Contact (never null).
     */
    private static Map<String, Contact> contactsByEmail(Set<String> emails) {
        Map<String, Contact> byEmail = new Map<String, Contact>();
        for (Contact c : ContactSelector.selectByEmails(emails)) {
            String key = normalizeKey(c.Email);
            if (key != null && !byEmail.containsKey(key)) {
                byEmail.put(key, c);
            }
        }
        return byEmail;
    }

    /**
     * Existing firm Accounts keyed by normalized name, OLDEST WINS (same ordering contract as
     * contactsByEmail).
     *
     * @param names trimmed, non-placeholder Lead companies; empty costs no SOQL.
     * @return normalized name -> the oldest matching Account (never null).
     */
    private static Map<String, Account> accountsByName(Set<String> names) {
        Map<String, Account> byName = new Map<String, Account>();
        for (Account a : AccountSelector.selectByNames(names)) {
            String key = normalizeKey(a.Name);
            if (key != null && !byName.containsKey(key)) {
                byName.put(key, a);
            }
        }
        return byName;
    }

    /**
     * The decision for one Lead.
     *
     * CONTACT WINS, AND DICTATES THE ACCOUNT. That ordering is a Salesforce constraint, not a
     * preference: a specified Contact's own Account must be the conversion target, so Lead.Company
     * is IGNORED whenever a Contact matched. The firm-only branch is reachable only when no
     * Contact matched; a placeholder Company is simply not a key in `accountByName` (see
     * collectMatchKeys), so D1b needs no guard here.
     *
     * @param l              the Lead whose match keys (Email, Company) to resolve.
     * @param contactByEmail normalized email -> oldest Contact, from contactsByEmail.
     * @param accountByName  normalized name -> oldest Account, from accountsByName.
     * @return the match, or NULL when nothing matched — the caller omits those Leads entirely so a
     *         Lead's absence from the map unambiguously means "convert with no attach target".
     */
    private static ConversionMatch resolveMatch(
        Lead l,
        Map<String, Contact> contactByEmail,
        Map<String, Account> accountByName
    ) {
        ConversionMatch match = new ConversionMatch();

        String emailKey = normalizeKey(l.Email);
        Contact matchedContact = (emailKey == null) ? null : contactByEmail.get(emailKey);
        if (matchedContact != null) {
            match.contactId = matchedContact.Id;
            match.accountId = matchedContact.AccountId;   // invariant; non-null by the selector filter
            return match;
        }

        String companyKey = normalizeKey(l.Company);
        Account matchedAccount = (companyKey == null) ? null : accountByName.get(companyKey);
        if (matchedAccount != null) {
            match.accountId = matchedAccount.Id;
            return match;
        }

        return null;
    }

    /**
     * FAIL SOFT — never break conversion for a user who can convert today. Returning an empty map
     * makes the caller attach nothing.
     *
     * ⚠ That is NOT the same as "what happened before this change": the always-on duplicate-rule
     * bypass shipped alongside this class and does not degrade, so a degraded run SUCCEEDS and
     * silently creates a duplicate where the pre-change behaviour was a loud DUPLICATES_DETECTED
     * block. Read the fail-soft section of the class header before relying on this — it states the
     * combined-change baseline and the two mitigations.
     *
     * @param e the denied-read exception, logged at ERROR for diagnosis.
     * @return an always-empty map.
     */
    private static Map<Id, ConversionMatch> degradeToNoMatch(System.QueryException e) {
        lastRunDegraded = true;
        System.debug(LoggingLevel.ERROR, 'LeadConvertMatchService.matchForConversion: read denied, '
            + 'degrading to no-match (conversion proceeds as before). ' + e.getMessage());
        return new Map<Id, ConversionMatch>();
    }

    /**
     * Trimmed value for use as a SOQL bind value.
     *
     * @param value the raw field value.
     * @return the trimmed value, or null when null/blank.
     */
    private static String trimToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    /**
     * Map key for a match value: trimmed AND lower-cased, or null when blank.
     *
     * The lower-casing is NOT redundant with the query. SOQL string comparison is case-insensitive,
     * so `WHERE Email IN :emails` can legitimately return a Contact stored as 'Broker@Firm.com' for
     * a Lead carrying 'broker@firm.com' — but Apex Map keys ARE case-sensitive, so grouping those
     * two on the raw strings would silently fail to pair the row with its Lead. Both sides are
     * normalized through this one method so they cannot diverge.
     *
     * @param value the raw field value (Lead.Email, Contact.Email, Lead.Company, Account.Name).
     * @return the trimmed, lower-cased key, or null when null/blank.
     */
    private static String normalizeKey(String value) {
        return String.isBlank(value) ? null : value.trim().toLowerCase();
    }
}
