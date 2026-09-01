/**
 * Runs on lead conversion (from LeadConvertTrigger). Conversion is the approval to
 * underwrite (no separate lead-approval gate), so the converting user is stamped on
 * the Opportunity as Lead Approved By. Beyond that, five jobs in one transaction:
 *
 *   1. Deal type / record type — carries the lead's Deal Type onto the new
 *      Opportunity and sets the matching Opportunity record type (Land or
 *      Retail) so the deal lands on the correct sales path. Standard
 *      conversion doesn't translate a custom picklist into the record-type
 *      choice, so we apply it here.
 *
 *      ⚠ CHANGED 2026-08-31: a BLANK Lead Deal Type now DEFAULTS to 'Retail' rather than
 *      leaving the deal untyped. It used to leave the Opportunity with no Deal Type and
 *      therefore no RecordTypeId, which costs the deal its Path AND both feasibility tabs on
 *      Opportunity_Record_Page. The default, why 'Retail', and why it is applied at conversion
 *      rather than at Lead intake are recorded in full at the one place it is applied, in
 *      buildOpportunityUpdates. 🔴 THE GOVERNOR CONTRACT BELOW IS UNCHANGED — the default is an
 *      in-memory choice of literal on a record already being written, plus one describe (not a
 *      query) on Opportunity.Deal_Type__c. No new read, no new statement.
 *
 *   2. Property creation — standard conversion only ever creates the
 *      Account, Contact, and Opportunity (all standard objects); it never
 *      creates the custom Property. So we create the Property the deal is about
 *      and link it to the Opportunity (Opportunity.Property__c), copying the
 *      seller's asking price and cap rate (from the lead's Guidance fields)
 *      plus the address, asset type, and Placer/CoStar links carried on the lead.
 *
 *      ⚠ CHANGED 2026-08-30 (WS3): "create" became "REUSE OR create". Two brokers emailing the
 *      same building used to produce two `Property__c` rows, so the building's underwriting,
 *      its CoStar/Placer links, its deal folder and its Property Management tree forked in
 *      two. Conversion now looks the building up first, by a stored normalized-address key, and
 *      LINKS to the existing row when one is found. 🔴 A REUSED PROPERTY IS NOT TOUCHED — see
 *      `createProperties` for the full decision and its two visible consequences.
 *
 *   3. CONVERSION ENRICHMENT (S1, 2026-08-03) — the deal-screening field set the
 *      Broker-Protection extraction pipeline writes onto the Lead used to DIE at
 *      conversion: the Opportunity arrived nearly empty. Conversion now SPLITS that
 *      set by meaning — DEAL-PROCESS facts (guidance range, offer due date, sale
 *      process, deal room, listing broker, parse confidence) go to the Opportunity;
 *      PHYSICAL PROPERTY facts (SF, NOI, units, occupancy, year built/renovated,
 *      lot acres, WALT, ADR, zoning, seller entity) go to the Property__c. Neither
 *      object gets the other half — that split IS the design, not an oversight.
 *
 *      ⚠ EXTENDED 2026-08-14 (Acquisition Observations, phase 1) by FOUR fields, all
 *      DEAL-PROCESS and therefore all to the Opportunity: `Listing_Status__c` (is the
 *      seller marketing this publicly?) plus the three extraction-completeness numbers
 *      `Extraction_Score_Pct__c` / `Fields_Captured_Count__c` / `Fields_Missing_Count__c`.
 *      🔴 THE GOVERNOR CONTRACT BELOW IS UNCHANGED BY THIS — same records, same statements,
 *      more fields on the SAME `update updates`. No new query, no new DML, and the one new
 *      picklist adds only a describe (not a query). A future change here that needs a
 *      SECOND read or a SECOND statement is a contract change and must say so.
 *
 *      ⚠ EXTENDED AGAIN 2026-08-17 (multi-property email grouping) by ONE field carried to
 *      BOTH sides — `Portfolio_Deal__c` onto the Opportunity (applyDealFields) AND onto
 *      the Property__c (buildProperty). It is the one enrichment field that is NOT split by
 *      meaning, because the grouping is a fact about the EMAIL rather than about the deal or
 *      the building: all three record types are members of the same one-to-many, so all
 *      three carry it. 🔴 THE GOVERNOR CONTRACT BELOW IS AGAIN UNCHANGED — two in-memory
 *      assignments on records already being written, zero queries, zero statements, and no
 *      picklist so not even a describe.
 *      ⚠ RENAMED 2026-08-18 (phase B4): this field was `Property_Package__c` when the note
 *      above was written. Both assignments were repointed; the old field still exists and is
 *      still populated until phase B5, and nothing here writes it any more.
 *      🔴 IT ANSWERS ONE QUESTION — "WHICH INBOUND BROKER EMAIL ROUTED THIS RECORD?" — AND
 *      MUST NEVER BE MADE TO ANSWER A SECOND. See the long warning at the assignment in
 *      applyDealFields: the deal-bundling question a human used to answer by hand ("which
 *      seller's bundle is this deal part of?") was a DIFFERENT fact with a different source
 *      and a different lifetime, it has now been retired from this org, and if it ever
 *      returns it needs its OWN new field rather than a widened meaning for this one. No
 *      test can detect that kind of repurposing, so that comment plus ARCHITECTURE.md §1/§2
 *      residual R1 are the only control.
 *
 *      ⚠ EXTENDED AGAIN 2026-08-30 (WS2, broker protection past conversion) by TWO fields, both
 *      DEAL-PROCESS and therefore both to the Opportunity: `Broker_First_Seen__c` (from
 *      `Lead.First_Seen_Date__c`) and `DPEG_First__c` (from `Lead.DPEG_First__c`). They carry the
 *      broker-protection window onto the deal, which until now ended at conversion.
 *      🔴 THE GOVERNOR CONTRACT BELOW IS AGAIN UNCHANGED — two in-memory assignments on a record
 *      already being written, zero queries, zero statements, no picklist and so not even a
 *      describe. `Opportunity.BP_Expiry__c` and `Opportunity.Days_in_System__c` are FORMULAS that
 *      derive from `Broker_First_Seen__c`; nothing here assigns them and nothing may.
 *      ⚠ THIS MADE A LIVE FIELD OUT OF A DEAD ONE, WHICH HAS BLAST RADIUS BEYOND THIS CLASS.
 *      `CallForOffersService`'s `dealArrivedDate` had ALWAYS resolved to its `CreatedDate` leg
 *      because nothing wrote `Broker_First_Seen__c`; from this change on, every newly converted
 *      deal takes the other leg, and the "Deal arrived <date>" text in `lwc/callForOffersList`
 *      moves from the Opportunity's creation moment to the broker-first-seen moment. That is
 *      correct and intended — see that class's header §4, amended in the same change.
 *
 *   4. BROKER CONTACT ROLE (S2, 2026-08-03) — the submitting broker becomes visible
 *      on the deal as a primary OpportunityContactRole with Role = 'Broker'.
 *
 *   5. BROKER RECORD TYPE STAMP (IR segregation, 2026-08-10) — Database.convertLead does NOT
 *      map record types onto the Contact or the Account it creates; they take whatever is
 *      default for the RUNNING USER'S PROFILE, which is unverifiable from source (profiles are
 *      .forceignore'd in this repo) and can differ per persona. This stamps Contact.Broker and
 *      Account.Broker_Firm deterministically, so the converted Account always lands on the
 *      record type the post-OWD-flip sharing rules key on — see stampConvertedPartyRecordTypes.
 *
 * ═══ THE OCR IS A READ-THEN-WRITE, NEVER A BLIND INSERT ═══
 * ⚠ STANDARD LEAD CONVERSION ALREADY CREATES AN OpportunityContactRole for the converted
 * Contact — IsPrimary = true, Role BLANK. Inserting our own row would therefore leave the
 * deal with TWO rows for one Contact and a second primary (Salesforce permits one primary
 * per Opportunity, so the insert either demotes the platform's row or fails; either way the
 * deal ends up wrong). So we read the existing rows through OpportunityContactRoleSelector
 * and UPDATE the matching (Opportunity, Contact) row, inserting only when none exists. That
 * is correct whether or not the platform creates the row — it does not depend on undocumented
 * conversion behaviour — and it is naturally idempotent if this path ever re-runs.
 *
 * ═══ BULK SHAPE IS A CONTRACT: 3 SOQL, ≤5 DML, CONSTANT — SOQL WAS 2, RAISED 2026-08-30 ═══
 * 🔴 THIS IS A DECLARED CONTRACT CHANGE, WHICH THE PREVIOUS VERSION OF THIS BLOCK DEMANDED BY
 * NAME: *"A future change here that needs a SECOND read or a SECOND statement is a contract change
 * and must say so."* WS3 (Property reuse) adds SOQL 3 below and makes DML 1 CONDITIONAL. Nothing
 * else moved: the new read is ONE call for the whole converted chunk, not one per Lead, and the new
 * conditional cannot raise the DML ceiling — it can only lower the count.
 *   SOQL 1 — RecordTypeSelector (Land / Retail)
 *   SOQL 2 — OpportunityContactRoleSelector (the rows conversion already created)
 *   SOQL 3 — PropertySelector.selectByNormalizedAddresses  (WS3, 2026-08-30) — the reuse lookup:
 *            ONE bulk `WHERE Normalized_Address__c IN :keys` for every converted Lead in the chunk.
 *            It is SKIPPED ENTIRELY (the selector short-circuits before issuing SOQL) when no Lead
 *            in the chunk carries an address at all, so the honest bound is "≤3, normally 3".
 *   DML  1 — Database.insert(properties, false)          🔴 NOW CONDITIONAL (WS3). It is
 *            isEmpty()-guarded, because a chunk in which EVERY Lead reuses an existing Property
 *            builds no rows at all — unguarded, that batch would spend a DML statement inserting
 *            an empty list. The reachable floor is therefore 4 statements, not 5.
 *   DML  2 — update updates                       (all-or-none, deliberately — see below)
 *   DML  3 — Database.update(roleUpdates, false)  ┐ the contact-role write, PARTITIONED.
 *   DML  4 — Database.insert(roleInserts, false)  ┘ Each is isEmpty()-guarded, and standard
 *            conversion always creates the role row, so the ORDINARY case is all-updates and
 *            spends exactly ONE statement here. A batch mixing deals that have a
 *            conversion-created role with deals that do not would spend both. That mixed batch
 *            is not reachable through this path (conversion behaves uniformly).
 *   DML  5 — Database.update(contactUpdates, false)  (IR segregation, 2026-08-10) — stamps
 *            Contact.Broker onto every converted Contact in the chunk, ONE statement.
 *   DML  6 — Database.update(accountUpdates, false)  (IR segregation, 2026-08-10) — stamps
 *            Account.Broker_Firm onto every DISTINCT converted Account in the chunk, ONE
 *            statement. "Distinct" matters here: several Leads can converge on ONE Account
 *            (LeadConvertMatchService reusing an existing broker firm), and a duplicate Id in
 *            one update statement throws DUPLICATE_VALUE — see stampConvertedPartyRecordTypes.
 *
 *   Both DML 5 and DML 6 are isEmpty()-guarded and CONSTANT IN BATCH SIZE — one statement for
 *   every converted Contact in the chunk, one for every distinct converted Account, never one
 *   per record. They are never both absent (every conversion produces a Contact and an
 *   Account), so the honest worst case actually reachable through this path is DML 1, 2, one of
 *   {3 or 4}, 5, 6 — five statements. The class-level contract is therefore 3 SOQL / ≤5 DML.
 *
 *   ⚠ WHY NOT ONE upsert: partitioning costs one conditional statement and removes an unknown.
 *   insert and update on OpportunityContactRole are certainly supported — the platform creates
 *   and edits these rows itself during conversion — whereas upsert support on this standard
 *   junction is not something this codebase has ever exercised. A runtime DML failure here does
 *   not fail politely: it is raised inside a Lead after-update trigger and takes the whole
 *   conversion with it.
 *
 * Constant regardless of batch size; nothing here queries or writes inside a loop. Picklist
 * getDescribe() calls are DESCRIBES, not queries, and consume no query limit.
 * LeadConvertServiceTest.bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities drives
 * 251 conversions in two convertLead chunks — so this service fires TWICE in one transaction
 * — and asserts the per-invocation bound. A future change that adds one query per Lead must
 * fail there, not in production.
 *
 * ═══ WHY EVERY RESTRICTED PICKLIST WRITE IS DESCRIBE-GUARDED ═══
 * `update updates` is ALL-OR-NONE and stays that way: the structural fields (RecordTypeId,
 * Property__c link, Lead_Approved_By__c) must land or the conversion is broken. But picklist
 * values bypass the compile checker — a code-first deploy goes green and then throws at
 * runtime — so ONE illegal value on ONE Lead would roll back the stamping for EVERY Lead in
 * the chunk, structural fields included. activePicklistValues() removes that failure mode at
 * source by dropping any value the target picklist does not actually offer, which keeps the
 * all-or-none guarantee affordable. The Property insert keeps Database.insert(..., false) for
 * the same reason it always had it: one bad Property must never roll back the conversion.
 *
 * ═══ FLS POSTURE — READ THIS BEFORE ASSUMING A BLANK FIELD IS A FAILED STAMP ═══
 * 🔴 CORRECTED 2026-08-30 (WS3), AND THE CORRECTION IS LOAD-BEARING. This paragraph used to say
 * flatly that "this service's DML runs in SYSTEM MODE". It runs in system mode only where the
 * ACCESS LEVEL IS STATED. `Database.insert(properties, false)` — the two-argument form this method
 * used for its entire life — was MEASURED on 2026-08-30 to be REFUSED with
 * `System.DmlException: Operation failed due to fields being inaccessible on Sobject Property__c`
 * as soon as the payload contained a field with no `FieldPermissions` row anywhere. The Property
 * insert therefore now passes `AccessLevel.SYSTEM_MODE` explicitly; see the long note at that
 * statement for why the alternative was a silent, org-wide loss of Property creation rather than an
 * error. Anything ADDED to this class that writes a newly-deployed field must state its access
 * level too — do not rely on "Apex DML is system mode by default".
 * Trigger.new is not FLS-filtered, so a missing FLS
 * grant does NOT block the stamp — the data lands. FLS is required only so the persona can SEE
 * the values; without it the highlight panel renders blank, silently. Verify as a real persona,
 * never as an admin (a System Administrator has no FLS on Metadata-API-deployed custom fields —
 * ARCHITECTURE.md §2). A blank field for the persona means a missing FLS grant, not a failed
 * stamp: query the row directly to tell the two apart.
 *
 * @see force-app/main/default/classes/OpportunityContactRoleSelector.cls
 * @see agent-output/design-requirements-conversion-enrichment.md (S1-S4, D-a..D-g)
 */
public with sharing class LeadConvertService {

    /** OpportunityContactRole.Role value identifying the submitting broker on a deal (S2). */
    private static final String BROKER_ROLE = 'Broker';

    /** Opportunity.Name is a Text field, max 120 characters. */
    private static final Integer OPPORTUNITY_NAME_MAX = 120;

    /** Property__c.Name is a Text field, max 80 characters. */
    private static final Integer PROPERTY_NAME_MAX = 80;

    /**
     * The Deal Type a converted deal takes when its Lead states NONE (2026-08-31).
     * The whole decision — why a default at all, why this value, and why HERE — is recorded at
     * the single place it is applied, in buildOpportunityUpdates. Read that block before
     * changing this constant; it is not a tunable.
     */
    private static final String DEFAULT_DEAL_TYPE = 'Retail';

    // ── ACTIVE VALUES OF EVERY RESTRICTED PICKLIST THIS CLASS WRITES ────────────────────────────
    // Resolved once per transaction and reused. getDescribe() is a DESCRIBE, not a query — it
    // consumes no SOQL limit — so the memoization is to keep the per-record stamping methods free
    // of picklist plumbing, not to save a limit. Holding them here rather than threading them
    // through every method as parameters is what keeps buildProperty / applyDealFields about the
    // record they are stamping.
    private static Set<String> assetTypeValuesCache;
    private static Set<String> opportunityAssetTypeValuesCache;
    private static Set<String> dealTypeValuesCache;
    private static Set<String> saleProcessValuesCache;
    private static Set<String> parseConfidenceValuesCache;
    private static Set<String> contactRoleValuesCache;
    private static Set<String> listingStatusValuesCache;

    /** Active values on Property__c.Asset_Type__c. */
    private static Set<String> assetTypeValues() {
        if (assetTypeValuesCache == null) {
            assetTypeValuesCache = activePicklistValues(Property__c.Asset_Type__c);
        }
        return assetTypeValuesCache;
    }

    /**
     * Active values on OPPORTUNITY.Asset_Type__c (Gap 1, 2026-08-31).
     *
     * ⚠ THIS IS NOT `assetTypeValues()` ABOVE, AND THE TWO MUST NEVER BE SWAPPED. That one holds
     * PROPERTY__C's value set and backs the Property stamp in buildProperty; this one holds
     * OPPORTUNITY's and backs the deal stamp in applyDealFields. They are separate field
     * definitions on separate objects: as of 2026-08-31 Opportunity's 8 values are exactly
     * Lead's 8, and Property__c carries those 8 PLUS C-Store and Storage. So they are not
     * interchangeable even while they overlap, and using the Property set here would let
     * `C-Store` / `Storage` through a guard whose whole job is to stop them.
     */
    private static Set<String> opportunityAssetTypeValues() {
        if (opportunityAssetTypeValuesCache == null) {
            opportunityAssetTypeValuesCache = activePicklistValues(Opportunity.Asset_Type__c);
        }
        return opportunityAssetTypeValuesCache;
    }

    /**
     * Active values on OPPORTUNITY.Deal_Type__c (the blank-deal-type default, 2026-08-31).
     *
     * ⚠ ADDED FOR THE DEFAULT, NOT FOR THE CARRY-OVER. Until 2026-08-31 this class wrote
     * `Deal_Type__c` unguarded, which was defensible while every value it wrote came off a Lead
     * that had already passed LLMExtractionParser's own describe validation. `DEFAULT_DEAL_TYPE`
     * is a LITERAL IN THIS FILE and has passed no such validation, so it is the one Deal Type
     * value that can be stale with respect to the org — exactly the case the class header's
     * "why every restricted picklist write is describe-guarded" paragraph exists for. Guarding
     * the whole assignment (rather than only the default leg) is what keeps the rule stated once.
     */
    private static Set<String> dealTypeValues() {
        if (dealTypeValuesCache == null) {
            dealTypeValuesCache = activePicklistValues(Opportunity.Deal_Type__c);
        }
        return dealTypeValuesCache;
    }

    /** Active values on Opportunity.Sale_Process__c. */
    private static Set<String> saleProcessValues() {
        if (saleProcessValuesCache == null) {
            saleProcessValuesCache = activePicklistValues(Opportunity.Sale_Process__c);
        }
        return saleProcessValuesCache;
    }

    /** Active values on Opportunity.Parse_Confidence__c. */
    private static Set<String> parseConfidenceValues() {
        if (parseConfidenceValuesCache == null) {
            parseConfidenceValuesCache = activePicklistValues(Opportunity.Parse_Confidence__c);
        }
        return parseConfidenceValuesCache;
    }

    /**
     * Active values on Opportunity.Listing_Status__c (observation 1, 2026-08-14).
     *
     * ⚠ THE SOURCE AND TARGET ARE TWO SEPARATE RESTRICTED PICKLISTS THAT MERELY MATCH TODAY.
     * `Lead.Listing_Status__c` and `Opportunity.Listing_Status__c` are independent field
     * definitions, so a value active on one is not thereby active on the other — the same
     * relationship `Sale_Process__c` already has, and the same one CallForOffersStampService's
     * header records for its own describe guard. Guarding here is what keeps
     * `update updates` affordably all-or-none.
     */
    private static Set<String> listingStatusValues() {
        if (listingStatusValuesCache == null) {
            listingStatusValuesCache = activePicklistValues(Opportunity.Listing_Status__c);
        }
        return listingStatusValuesCache;
    }

    /** Active values on OpportunityContactRole.Role (the ContactRole standard value set). */
    private static Set<String> contactRoleValues() {
        if (contactRoleValuesCache == null) {
            contactRoleValuesCache = activePicklistValues(OpportunityContactRole.Role);
        }
        return contactRoleValuesCache;
    }

    /**
     * Called from the Lead after-update trigger. For each lead that just
     * converted (and created an Opportunity): build its Property, stamp the
     * Opportunity's Property link / Deal Type / RecordTypeId plus the deal-process
     * field set, and put the converted Contact on the deal as the primary Broker.
     */
    public static void stampConvertedOpportunities(List<Lead> newLeads, Map<Id, Lead> oldMap) {
        Map<Id, Lead> oppToLead = justConvertedByOpportunity(newLeads, oldMap);
        if (oppToLead.isEmpty()) {
            return;
        }
        // 1. Reuse or build the Property for each converted deal, and link it back to its
        //    Opportunity.  [SOQL 3, DML 1 — the DML is conditional as of WS3]
        Map<Id, Id> oppToPropertyId = createProperties(oppToLead);
        // 2. Stamp every Opportunity: structural fields plus the deal-process set.  [SOQL 1, DML 2]
        List<Opportunity> updates = buildOpportunityUpdates(oppToLead, oppToPropertyId);
        // 🔴 STILL ALL-OR-NONE (the `true`), AND NOW EXPLICITLY SYSTEM MODE. Both halves matter and
        // neither is cosmetic.
        //
        // ⚠ THE ACCESS LEVEL WAS FOUND THE HARD WAY ON 2026-08-30, VALIDATING WS3, AND THE DEFECT
        // IT FIXES IS A TOTAL, ORG-WIDE, SILENT-UNTIL-CLICKED OUTAGE OF LEAD CONVERSION. The bare
        // `update updates;` this line replaces was refused outright the moment WS2 added
        // `o.DPEG_First__c = l.DPEG_First__c` to `applyDealFields`:
        //     System.DmlException: Operation failed due to fields being inaccessible on
        //     Sobject Opportunity
        // which, raised inside a Lead after-update trigger, surfaces to the user as
        // `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY ... There was an error converting the lead` and
        // rolls the WHOLE conversion back. Measured: 28 of the 30 methods in
        // `LeadConvertServiceTest` failed on it, including every pre-existing one that has nothing
        // to do with broker protection. `Opportunity.DPEG_First__c` is deployed by the Metadata API
        // and this work grants it to nobody, so it has no `FieldPermissions` row for ANY profile,
        // System Administrator included — and such a field is not FLS-denied, it is ABSENT from the
        // running user's schema, which the DML layer refuses rather than ignores.
        //
        // 🔴 "APEX DML IS SYSTEM MODE BY DEFAULT" IS THE BELIEF THAT PRODUCED THIS. It governs
        // ENFORCEMENT on a field the running user can see; it does not put back a field that is not
        // in their schema. Only a stated AccessLevel does. The same fact forced the explicit
        // AccessLevel on the Property insert in `createProperties`, for the same reason.
        //
        // ⚠ AN FLS GRANT IS NOT AN ALTERNATIVE FIX, IT IS A SECOND, WEAKER ONE. Granting
        // `DPEG_First__c` on `DPEG_Acquisition_Edit` would fix conversion only for personas holding
        // that set, and would leave the deploy-time `RunLocalTests` pass failing for any admin who
        // does not — which is how this reached a validation run in the first place. The grant is
        // still wanted (a human has to SEE the value); it is not what keeps conversion working.
        Database.update(updates, true, AccessLevel.SYSTEM_MODE);
        // 3. Put the converted Contact on the deal as the primary Broker.  [SOQL 2, DML 3/4]
        stampBrokerContactRoles(oppToLead);
        // 4. Stamp the converted Contact and Account with their broker record types.  [DML 5, DML 6]
        stampConvertedPartyRecordTypes(oppToLead.values());
    }

    /**
     * The leads that just converted in this transaction (IsConverted false -> true) AND produced
     * an Opportunity, keyed by that Opportunity. The false->true edge is what makes the stamp fire
     * exactly once per lead, so nothing downstream needs its own re-entry guard.
     */
    private static Map<Id, Lead> justConvertedByOpportunity(List<Lead> newLeads, Map<Id, Lead> oldMap) {
        Map<Id, Lead> oppToLead = new Map<Id, Lead>();
        for (Lead l : newLeads) {
            Lead prior = (oldMap == null) ? null : oldMap.get(l.Id);
            Boolean justConverted = l.IsConverted && (prior == null || !prior.IsConverted);
            if (justConverted && l.ConvertedOpportunityId != null) {
                oppToLead.put(l.ConvertedOpportunityId, l);
            }
        }
        return oppToLead;
    }

    /**
     * REUSES an existing Property where the converted deal names a building this org already
     * holds, and inserts one only where it does not. Returns Opportunity Id -> Property Id for
     * every deal that ended up with a Property (reused or newly inserted).
     *
     * ═══ WS3 (2026-08-30) — WHY THIS STOPPED BEING A BLIND INSERT ═══
     * Until this change every conversion minted a `Property__c`, so two brokers emailing the SAME
     * building produced two rows for it. That is not a cosmetic duplicate: `Property__c` is the
     * root of the acquisition graph, so the building's underwriting figures, its CoStar/Placer
     * links, its SharePoint deal folder and (at Closed Won) its Property Management asset tree all
     * forked in two, and no screen showed that they had. Competing brokers on one building is the
     * scenario Broker Protection exists for — it is the ordinary case here, not an edge case.
     *
     * ═══ 🔴 A REUSED PROPERTY IS NOT MODIFIED. NOT ONE FIELD, NOT EVEN A BLANK ONE. ═══
     * USER DECISION, taken deliberately over both "overwrite" and the softer "fill in the blanks".
     * The existing row's values are CURATED — an analyst's underwriting, or data synced from
     * CoStar/Placer — and the second broker's email is an unreviewed LLM extraction. Blank-filling
     * sounds free and is not: `Occupancy_Pct__c` empty because nobody has measured it and
     * `Occupancy_Pct__c` empty because an analyst DELETED a wrong number are indistinguishable from
     * here, and the second is silently overwritten by the machine. So the newer facts are
     * DISCARDED on purpose, and this method holds no update path at all — there is nothing to
     * disable if the decision is ever revisited, only something to add.
     *
     * TWO CONSEQUENCES, BOTH VISIBLE TO USERS, BOTH ACCEPTED:
     *   ⚠ 1. `Opportunity.Property_Address__c` is a CROSS-OBJECT FORMULA over `Property__r
     *         .Address__c`, so the second deal displays the FIRST broker's wording of the address
     *         rather than the wording in its own email. The second email's wording is not lost —
     *         it survives verbatim on `Lead.Property_Address__c`, a stored Text field on the
     *         converted Lead, which is where to look when the two disagree.
     *   ⚠⚠ 2. SHARING. `Property__c` OWD is Private and the reuse lookup deliberately escapes
     *         sharing (`PropertySelector.ReuseLookupReads` — it has to, or a converter who cannot
     *         see the first Property would read "no such building" and mint the duplicate this
     *         feature exists to prevent). So the Opportunity can now point at a Property its own
     *         converter cannot open: the lookup renders, and clicking through gives INSUFFICIENT
     *         PRIVILEGES. That is correct per the decision — the reuse is a system fact about the
     *         building, not a grant of access to it — but it is a NEW user-visible condition and
     *         belongs in the release note. The remedy is a permission-set grant
     *         (`DPEG_Property_View` / `DPEG_Acquisition_View`), never a narrowing of that read.
     *
     * ═══ BULK SHAPE — ONE QUERY FOR THE WHOLE CHUNK, NEVER ONE PER LEAD ═══
     * Step 1 is pure in-memory key derivation; step 2 is the single `PropertySelector` call
     * [SOQL 3]; step 3 builds rows only for the keys that missed. This service fires TWICE in one
     * transaction on a 251-conversion batch (`Database.convertLead` caps a call at 200), which is
     * why the per-INVOCATION cost is what matters and why
     * `LeadConvertServiceTest.stampCostDoesNotScaleWithBatchSize` compares a 1-record run against a
     * 50-record one rather than asserting a ceiling.
     *
     * ═══ WITHIN-BATCH DEDUPE — THE CASE THE QUERY CANNOT SEE ═══
     * One inbound email naming the same building twice, or two Leads for one building converted in
     * the same chunk, both key identically and BOTH miss the query (neither Property exists yet).
     * Building one row per Lead would re-create the exact duplicate this method removes, one
     * transaction later. So a key that has already claimed a row in `properties` reuses that row's
     * INDEX, and both Opportunities take the same inserted Id. Iteration is over a SORTED list of
     * Opportunity Ids so that "which of the two Leads' facts become the new Property" is
     * deterministic (the lower Opportunity Id wins) rather than dependent on Map iteration order.
     *
     * ═══ A LEAD WITH NO ADDRESS AT ALL GETS ITS OWN PROPERTY, ALWAYS ═══
     * `normalizeAddress` returns '' for a blank address. A blank key is NEVER looked up and NEVER
     * stamped — it is not a key, it is the absence of one. Were it treated as a key, every
     * addressless deal in the org would collapse onto one shared "building". Branch (c) of the
     * broker-protection routing tree legitimately produces addressless Leads, so this is a live
     * path, not a defensive nicety.
     *
     * allOrNone = false, unchanged: a single bad Property must never roll back the whole
     * conversion. The cost is that a failed row simply leaves Opportunity.Property__c null (and
     * with it the Property_Address__c formula blank) rather than raising — deliberate, and the same
     * posture the class has had since it was written.
     */
    private static Map<Id, Id> createProperties(Map<Id, Lead> oppToLead) {
        // Sorted for determinism — see the within-batch dedupe note above. Id ordering is total,
        // stable across runs, and needs no extra state on the Lead.
        List<Id> oppIds = new List<Id>(oppToLead.keySet());
        oppIds.sort();

        // ── 1. Derive every key, in memory. Zero SOQL, zero DML. ────────────────────────────────
        Map<Id, String> keyByOpp = new Map<Id, String>();
        Set<String> keys = new Set<String>();
        for (Id oppId : oppIds) {
            // 🔴 THE SAME PRECEDENCE buildProperty USES FOR Address__c, VIA THE SAME HELPER. If the
            // key were derived from a different field than the address that gets stored, the row
            // this method inserts would not be findable by the key it was inserted under, and reuse
            // would fail for exactly the buildings it just created.
            String key = PropertyMatchingService.normalizeAddress(propertyAddress(oppToLead.get(oppId)));
            keyByOpp.put(oppId, key);
            if (String.isNotBlank(key)) {
                keys.add(key);
            }
        }

        // ── 2. ONE read for the whole chunk. [SOQL 3] ───────────────────────────────────────────
        // First row per key wins, and the selector orders oldest-first, so reuse converges on the
        // ORIGINAL Property when the org holds pre-existing duplicates (Normalized_Address__c is
        // deliberately not unique — the backfill has to be able to land on a dirty org).
        //
        // ⚠ `.toLowerCase()` ON BOTH SIDES OF THIS MAP CLOSES A GENUINE MISMATCH, NOT A HYPOTHETICAL
        // ONE. `Normalized_Address__c` is `caseSensitive = false`, so the SOQL `IN` above matches
        // CASE-BLIND at the index — but an Apex `Map<String, ...>` lookup is CASE-SENSITIVE. A row
        // whose stored key differed only in case would therefore come BACK from the query and then
        // silently MISS here, and the visible result would be a duplicate Property with no error.
        // `normalizeAddress` lower-cases before it returns, so in practice both sides are already
        // lower and this is a no-op; it costs one string operation per row and removes the one way
        // the two matchers can disagree.
        Map<String, Id> existingByKey = new Map<String, Id>();
        for (Property__c existing : PropertySelector.selectByNormalizedAddresses(keys)) {
            String foundKey = existing.Normalized_Address__c.toLowerCase();
            if (!existingByKey.containsKey(foundKey)) {
                existingByKey.put(foundKey, existing.Id);
            }
        }

        // ── 3. Build rows ONLY for the misses. ──────────────────────────────────────────────────
        Map<Id, Id> oppToPropertyId = new Map<Id, Id>();
        List<Property__c> properties = new List<Property__c>();
        Map<Id, Integer> rowIndexByOpp = new Map<Id, Integer>(); // opp -> its row in `properties`
        Map<String, Integer> rowIndexByKey = new Map<String, Integer>(); // within-batch dedupe
        for (Id oppId : oppIds) {
            // Lower-cased for the same reason the map above is — see that comment.
            String key = keyByOpp.get(oppId);
            Boolean keyed = String.isNotBlank(key);
            String lookupKey = keyed ? key.toLowerCase() : null;
            if (keyed && existingByKey.containsKey(lookupKey)) {
                // REUSE. No DML, no field written, nothing on the existing row touched.
                oppToPropertyId.put(oppId, existingByKey.get(lookupKey));
                continue;
            }
            if (keyed && rowIndexByKey.containsKey(lookupKey)) {
                // A second Lead for the same building INSIDE this chunk — share the pending row.
                rowIndexByOpp.put(oppId, rowIndexByKey.get(lookupKey));
                continue;
            }
            Integer rowIndex = properties.size();
            properties.add(buildProperty(oppToLead.get(oppId)));
            rowIndexByOpp.put(oppId, rowIndex);
            if (keyed) {
                rowIndexByKey.put(lookupKey, rowIndex);
            }
        }

        // ── 4. [DML 1] — isEmpty()-GUARDED, WHICH IT DID NOT USED TO NEED. ──────────────────────
        // A chunk in which every Lead reuses an existing Property builds no rows, and
        // `Database.insert` on an empty list still spends a DML statement. Guarding is what keeps
        // the header's ≤5 an honest ceiling rather than a floor.
        //
        // 🔴 `AccessLevel.SYSTEM_MODE` IS EXPLICIT AS OF WS3, AND IT IS NOT A WIDENING — IT IS THE
        // CLASS HEADER'S "FLS POSTURE" PARAGRAPH BECOMING TRUE. That paragraph has always asserted
        // "this service's DML runs in SYSTEM MODE, so a missing FLS grant does NOT block the
        // stamp". MEASURED 2026-08-30 against usman-dpeg at API 67.0, that was FALSE for a field
        // nobody has been granted: `Database.insert(properties, false)` — the two-argument form —
        // was REFUSED with
        //     System.DmlException: Operation failed due to fields being inaccessible on
        //     Sobject Property__c
        // the moment `Normalized_Address__c` appeared in the payload. A Metadata-API-deployed
        // custom field arrives with NO field permissions for ANY profile, System Administrator
        // included, and such a field is not merely FLS-denied — it is ABSENT from the running
        // user's schema, which the DML layer reports as inaccessible rather than ignoring.
        //
        // ⚠ WHY THAT WOULD HAVE BEEN A SILENT, TOTAL OUTAGE RATHER THAN AN ERROR. `allOrNone`
        // is false here, deliberately, so the refusal does not throw — it fails EVERY row in the
        // list, `oppToPropertyId` comes back empty, and every converted deal in the chunk ends up
        // with a null `Property__c` and a blank `Property_Address__c` formula. Not just WS3's reuse:
        // PROPERTY CREATION ITSELF, for every conversion in the org, which is behaviour this class
        // has had since it was written. So the explicit AccessLevel is what keeps THIS change from
        // being the largest regression in the file.
        //
        // ⚠ IT DOES NOT LIFT SHARING (an insert has no existing rows to be filtered by) and it does
        // NOT change this class's `with sharing` declaration. It also does not remove the need for
        // the P8 FLS grant on `Normalized_Address__c`: the grant is what lets a HUMAN see the field
        // and what the backfill script depends on (anonymous Apex cannot use SYSTEM_MODE at all).
        if (!properties.isEmpty()) {
            Database.SaveResult[] saves = Database.insert(properties, false, AccessLevel.SYSTEM_MODE);
            for (Id oppId : rowIndexByOpp.keySet()) {
                Database.SaveResult save = saves[rowIndexByOpp.get(oppId)];
                if (save.isSuccess()) {
                    oppToPropertyId.put(oppId, save.getId());
                }
            }
        }
        return oppToPropertyId;
    }

    /**
     * The address a converted Lead is ABOUT: the extracted property address when it has one, the
     * standard Street otherwise.
     *
     * Extracted 2026-08-30 (WS3) from `buildProperty`, where this expression already lived, so that
     * `createProperties` derives the reuse KEY from exactly the string `buildProperty` stores in
     * `Address__c`. Two copies of this precedence would be a silent divergence: the key would
     * describe one address and the record another, and every reuse lookup would miss.
     *
     * @param l The converted lead.
     * @return The address, or null when the lead carries neither field.
     */
    private static String propertyAddress(Lead l) {
        return String.isNotBlank(l.Property_Address__c) ? l.Property_Address__c : l.Street;
    }

    /**
     * One update record per converted Opportunity: the STRUCTURAL fields (approver, Property link,
     * deal type, record type) plus the deal-process field set. Returned rather than written so the
     * caller keeps the single `update` statement visible at the top level — that statement is
     * all-or-none by design, which is why every picklist write below it is describe-guarded.
     */
    private static List<Opportunity> buildOpportunityUpdates(
        Map<Id, Lead> oppToLead,
        Map<Id, Id> oppToPropertyId
    ) {
        Map<String, Id> rtByName = new Map<String, Id>();
        // 'Retail' (was 'Commercial') — the Deal Type migration, phase 1 D3. The set is matched
        // against RecordType.DeveloperName, so it moves with the record type's DEVELOPER NAME,
        // not its label; a label-only rename would have left this saying 'Commercial' forever.
        for (RecordType rt : RecordTypeSelector.selectByObjectAndDeveloperNames(
                'Opportunity', new Set<String>{ 'Land', 'Retail' })) {
            rtByName.put(rt.DeveloperName, rt.Id);
        }

        List<Opportunity> updates = new List<Opportunity>();
        for (Id oppId : oppToLead.keySet()) {
            Lead l = oppToLead.get(oppId);
            Opportunity o = new Opportunity(Id = oppId);
            // Conversion IS the approval to underwrite: the converting user is the approver.
            o.Lead_Approved_By__c = UserInfo.getUserId();
            // S2b (2026-08-05) — mirror the submitting broker onto a LOOKUP as well as the
            // OpportunityContactRole created below. The role alone was invisible in practice: a
            // contact role is a related list, so it cannot appear in the highlights panel, a
            // compact layout, a list view column or a report column on the Opportunity. Riding on
            // this existing loop leaves the class's governor contract EXACTLY as documented in the
            // header — the value is already on the Lead, so this adds no query and no
            // statement. (Do not restate the numbers here: they were restated as "2 SOQL" and went
            // stale the moment WS3 raised the header to 3. The header is the single statement of
            // the contract; these in-method notes say only "unchanged by this line".)
            // ⚠ This is the SUBMITTING broker; the OM's listing broker is a different
            // person and lives in Listing_Broker_Name__c / Listing_Broker_Email__c (set by
            // applyDealFields below). Do not merge the two.
            if (l.ConvertedContactId != null) {
                o.Broker__c = l.ConvertedContactId;
            }
            if (oppToPropertyId.containsKey(oppId)) {
                o.Property__c = oppToPropertyId.get(oppId);
            }
            // ── BLANK DEAL TYPE DEFAULTS TO RETAIL (2026-08-31) ──────────────────────────────
            // WHAT THIS DOES. A Lead that states no Deal Type converts to a Retail-typed
            // Opportunity instead of an untyped one. Before this line the whole block was
            // wrapped in `if (String.isNotBlank(l.Deal_Type__c))`, so a blank Lead produced an
            // Opportunity with NO Deal Type and — because the record type is derived from it —
            // NO RecordTypeId at all. Measured live on 2026-08-31: Opportunity
            // 006iw000000fgpiAAA ("Marrowbrook Station Medical Plaza") landed with
            // RecordTypeId = null from a Lead whose extraction returned deal_type = null.
            //
            // 🔴 THE COST OF A NULL RECORD TYPE IS NOT COSMETIC, WHICH IS WHY A DEFAULT IS
            // JUSTIFIED AT ALL. Three separate things break, and only the first is obvious:
            //   1. no record type => no Path on the deal, and no record-type picklist subset
            //      acting as a backstop on any picklist the deal carries;
            //   2. flexipages/Opportunity_Record_Page gates its Development tab on
            //      Deal_Type__c = Land and its Construction tab on = Retail. A NULL matches
            //      NEITHER, so the feasibility-review section of the page vanishes entirely —
            //      defaulting only RecordTypeId would have left the page half-broken, which is
            //      why the default belongs on the FIELD and the record type follows from it;
            //   3. eight classes read Deal_Type__c (BrokerPortalController, BrokerPortalService,
            //      EmailToLeadService, this class, LLMExtractionCalloutService,
            //      LLMExtractionParser, OpportunityFunnelController, OpportunitySelector) and a
            //      null is an unhandled third state in every one of them.
            //
            // WHY 'Retail' AND NOT SOME NEW 'Unknown' VALUE. Deal_Type__c is a two-value
            // LAND / NOT-LAND discriminator whose ONLY job is selecting the Opportunity record
            // type. It is NOT an asset category, despite sharing the token 'Retail' with
            // Asset_Type__c — a hotel is correctly Deal_Type__c = Retail and
            // Asset_Type__c = Hospitality at the same time. 'Retail' is literally "everything
            // that is not raw land", so it is the correct bucket for an unstated deal type, and
            // the meaning is ASYMMETRIC: only 'Land' carries positive information. A third value
            // would break the record-type lookup, both record types' picklist subsets, and the
            // page's two tab-visibility rules.
            //
            // 🔴 WHY AT CONVERSION AND NOT AT INTAKE (EmailToLeadService). The LEAD must stay an
            // honest record of what the email actually said: a null Deal_Type__c there correctly
            // means "the broker did not state a deal type", and it is the field the extraction
            // audit trail (Extracted_JSON__c, the per-field confidence map) is checked against.
            // Defaulting on the Lead would fabricate an extraction result and make the intake
            // data lie about its own source — no later reader could tell a stated 'Retail' from
            // an assumed one. The OPPORTUNITY is the working record: it needs a record type, a
            // Path and functioning tabs, and it already carries derived-at-conversion values
            // (Lead_Approved_By__c, the Property link) so a derived Deal Type is in keeping.
            //
            // 🔴 THIS IS NOT DEAD CODE AND MUST NOT BE DELETED WHEN THE PROMPT IS FIXED. The
            // UPSTREAM cause is a prompt gap another stream is fixing: `deal_type` is a
            // TEMPLATE-ONLY key in the extraction prompt — it appears in the JSON response
            // shape, in the blanket "must be one of the listed values or null" line and in the
            // `deal_type must be one of: Land, Retail` enum, and NOWHERE is there a sentence
            // saying what the two values MEAN. That is why the model returned 'Retail' for two
            // hotels but null for a medical-office and an industrial deal. When that fix lands,
            // blanks become rare and this default becomes a FALLBACK rather than the normal
            // path. It is still load-bearing then: the broker portal and manual Lead entry can
            // both produce a blank Deal Type with no LLM involved at all, and a prompt is not a
            // guarantee. Judge it by the live count of untyped Opportunities, never by "the
            // extraction fills this in now".
            //
            // The describe guard is the class header's standing rule, and it matters MORE here
            // than for the carry-over it replaces: `update updates` is all-or-none, so writing a
            // value the Opportunity picklist does not offer would roll back the stamping for
            // every Lead in the chunk, structural fields included. Verified on usman-dpeg
            // 2026-08-31 (savepoint probe, rolled back): a Retail-typed Opportunity carrying
            // Asset_Type__c = 'Medical Office' is ACCEPTED, so the default does not collide with
            // the Retail record type's Asset_Type__c subset. Keep it that way — see
            // activePicklistValues' header for why this guard is field-level and record-type-blind.
            String dealType = picklistValueOrNull(
                String.isNotBlank(l.Deal_Type__c) ? l.Deal_Type__c : DEFAULT_DEAL_TYPE,
                dealTypeValues()
            );
            if (dealType != null) {
                o.Deal_Type__c = dealType;
                Id rtId = rtByName.get(dealType); // dealType is 'Land' or 'Retail'
                if (rtId != null) {
                    o.RecordTypeId = rtId;
                }
            }
            applyDealFields(o, l);
            updates.add(o);
        }
        return updates;
    }

    /**
     * Copies the lead's DEAL-PROCESS field set onto the Opportunity (S1). The physical
     * property facts deliberately do NOT come here — they go to the Property__c in
     * buildProperty. Every target field mirrors its Lead source's type, length, precision
     * and scale exactly, and InboundEmailFieldUtil already clipped the Lead values at the
     * email boundary, so nothing needs re-clipping here.
     *
     * Every field on a freshly created Opportunity is empty at this instant, so there is no
     * "don't clobber the analyst" branch — adding one would be untestable dead code today and
     * would mask a real bug tomorrow.
     */
    private static void applyDealFields(Opportunity o, Lead l) {
        // ⚠ Asking_Price__c is the aggregation column behind OpportunitySelector
        // .aggregateOpenPipeline (open-pipeline value KPI) and the ordering key of
        // selectTopByAskingPrice. Stamping it makes email-born deals count toward both for
        // the first time — correct, but a visible jump on the next dashboard refresh.
        o.Asking_Price__c = l.Guidance_Price__c;
        // A RANGE-PRICED DEAL LEAVES Asking_Price__c NULL, DELIBERATELY. The extraction prompt's
        // own rule fills guidance_price_low/high and leaves guidance_price null for a range, and
        // synthesizing a midpoint here would FABRICATE a price — the exact behaviour this module
        // forbids everywhere else. Such a deal contributes 0 to the pipeline KPI until an analyst
        // fills it in. Accepted and pinned by LeadConvertServiceTest.
        o.Guidance_Price_Low__c = l.Guidance_Price_Low__c;
        o.Guidance_Price_High__c = l.Guidance_Price_High__c;
        // F1 (approved at Gate 1, 2026-08-03): the cap-rate twin of Asking_Price__c. Without it
        // the deal shows a price and no cap rate — an asymmetric pair that reads as a defect.
        o.Guidance_Cap_Rate__c = l.Guidance_Cap_Rate__c;
        o.Offer_Due_Date__c = l.Offer_Due_Date__c;
        o.Deal_Room_Link__c = l.Deal_Room_Link__c;
        o.Listing_Broker_Name__c = l.Listing_Broker_Name__c;
        o.Listing_Broker_Email__c = l.Listing_Broker_Email__c;
        // Restricted picklists — see the class header. An unknown value is DROPPED, never pushed.
        o.Sale_Process__c = picklistValueOrNull(l.Sale_Process__c, saleProcessValues());
        o.Parse_Confidence__c = picklistValueOrNull(l.Parse_Confidence__c, parseConfidenceValues());
        // ── Acquisition Observations phase 1 (2026-08-14) ────────────────────────────────────
        // Listing status is a DEAL-PROCESS fact — is the seller marketing this publicly? — so it
        // comes HERE and never to the Property__c, exactly like sale process and the offer due
        // date. The field's own metadata comment states the same split, so the two cannot drift.
        // ⚠ NOT Broker_Listing__c.Listing_Status__c, which is the disposition side's On Track / …
        // performance picklist. Nothing may ever map between them.
        o.Listing_Status__c = picklistValueOrNull(l.Listing_Status__c, listingStatusValues());
        // ── GAP 1 (2026-08-31) — ASSET TYPE, CARRIED PAST CONVERSION ──────────────────────────
        // Until this line the asset type died at conversion: LeadConvertService wrote it to the
        // Property__c (buildProperty, below) and to NOTHING else, so every email-born deal reached
        // OpportunityFunnelController with Asset_Type__c null and the funnel reported a null asset
        // type for all of them. This one assignment is the whole of the fix.
        //
        // THE HEADER'S GOVERNOR CONTRACT IS UNCHANGED. Read the numbers off the header, never off
        // this line — the WS2 comment below records that restating them here has gone stale twice.
        // The value is already on `l` (a Trigger.new record) and `o` is already in the `updates`
        // list the caller writes with ONE statement: zero new queries, zero new DML. The describe
        // behind opportunityAssetTypeValues() is a describe, not a query, and consumes no SOQL.
        //
        // 🔴 THE GUARD HERE IS NOT THE REAL CONTROL — THE THREE-FILE LOCKSTEP IS. See
        // activePicklistValues at the bottom of this class: it reads a FIELD describe and cannot
        // see the Land/Retail record-type value subsets. Keeping Lead's 8 values, Opportunity's
        // field value set and BOTH Opportunity record-type blocks aligned is what makes this write
        // total; the guard only degrades a FIELD-level drift to a silent null.
        o.Asset_Type__c = picklistValueOrNull(l.Asset_Type__c, opportunityAssetTypeValues());
        // The three extraction-completeness numbers travel TOGETHER and unguarded — they are
        // Number(3,0) mirrors of their Lead sources, so there is no picklist to validate and no
        // clipping to do. Carrying all three (rather than the percent alone) is what keeps the
        // denominator RECOVERABLE per record as captured + missing; see ExtractionScoreUtil's
        // header for why that property is load-bearing and must not be "simplified" away.
        // ⚠ NULL IS A MEANINGFUL VALUE AND IS COPIED AS-IS. It reads "not scored" — the LLM-down
        // path — which is not the same as a zero score, and a `!= null` guard here would be
        // indistinguishable from one on a freshly created Opportunity anyway (every field is
        // empty at this instant, which is why nothing else in this method guards either).
        o.Extraction_Score_Pct__c = l.Extraction_Score_Pct__c;
        o.Fields_Captured_Count__c = l.Fields_Captured_Count__c;
        o.Fields_Missing_Count__c = l.Fields_Missing_Count__c;

        // ── WS2 (2026-08-30) — THE BROKER-PROTECTION PAIR, CARRIED PAST CONVERSION ──────────────
        // Until this change the protection window DIED at conversion. `Opportunity
        // .Broker_First_Seen__c` had NO writer anywhere in this repo — only two seed scripts
        // backdated it — so a converted deal could not say when DPEG first saw it, and the
        // Opportunity had no equivalent of Lead.BP_Expiry__c / Lead.Days_in_System__c at all.
        // These two assignments are the whole of the fix.
        //
        // 🔴 THE HEADER'S GOVERNOR CONTRACT IS UNCHANGED BY WS2, AND A REVIEWER MUST NOT READ THIS
        // AS A BREACH. (Read the numbers off the header, never off this line — this comment used to
        // restate them as "2 SOQL / ≤5 DML" and was stale from the moment WS3 raised SOQL to 3.)
        // Both values are already on `l` (a Trigger.new
        // record) and `o` is already a member of the `updates` list the caller writes with ONE
        // statement: zero new queries, zero new statements, and no picklist so not even a describe.
        // Exactly the shape the Portfolio_Deal__c carry-forward below already has.
        //
        // ⚠ BOTH SIDES ARE DateTime, AND THAT SYMMETRY IS THE POINT OF THE WS2 FIELD TYPE CHANGE.
        // `Lead.First_Seen_Date__c` is a DateTime despite its Date-suffixed name (a pre-existing
        // ARCHITECTURE.md §1 violation, deliberately NOT "fixed" here — a rename is a
        // delete-and-create), and `Broker_First_Seen__c` moved Date -> DateTime in this same change
        // so the instant maps straight across. A `.date()` on this line would silently discard the
        // time of day and re-introduce exactly what the type change removed.
        //
        // 🔴 BP_Expiry__c AND Days_in_System__c ARE FORMULA FIELDS AND ARE NOT ASSIGNED HERE. They
        // derive from Broker_First_Seen__c the moment it lands. Assigning a formula field is a
        // COMPILE error, not a runtime one; they are named here so nobody adds them "for
        // completeness" after reading the field list on the layout.
        //
        // ⚠ NULL IS COPIED AS-IS, for the same reason as the three extraction numbers above: every
        // field on a freshly created Opportunity is empty at this instant, so a `!= null` guard
        // would be indistinguishable from no guard and would mask a real bug later. In practice
        // neither source is normally blank — flows/Lead_Intake_Stamp stamps First_Seen_Date__c on
        // every Lead save where it IsNull, and DPEG_First__c on every save where it IsNull AND the
        // owner is a User. The one reachable blank is a QUEUE-OWNED Lead, which converts with
        // DPEG_First__c empty and leaves the Opportunity's empty too — the honest answer ("no DPEG
        // user had this first"), not a failed stamp.
        o.Broker_First_Seen__c = l.First_Seen_Date__c;
        o.DPEG_First__c = l.DPEG_First__c;

        // ── The multi-property PORTFOLIO DEAL, carried forward (2026-08-17) ──────────────────
        // One inbound broker email that named several properties produced several Leads, all
        // stamped with one Portfolio_Deal__c at insert (Decision C1). Carrying it here is what
        // keeps the grouping alive AFTER conversion, so the Acquisitions team can still see that
        // three deals came off one email.
        //
        // ZERO SOQL AND ZERO DML: `l` is a Trigger.new record that already carries the value and
        // `o` is already in the `updates` list this method's caller writes with ONE statement — so
        // the governor contract stated in the class header is UNCHANGED. It is a lookup, not a
        // picklist, so there is nothing to describe-guard; a SetNull delete constraint means a
        // deleted portfolio deal blanks this field rather than cascading into the deal.
        //
        // 🔴 THIS LOOKUP ANSWERS EXACTLY ONE QUESTION, AND MUST NEVER BE MADE TO ANSWER A SECOND:
        // "WHICH INBOUND BROKER EMAIL ROUTED THIS RECORD?" It is PIPELINE-DERIVED — one broker email
        // -> many Leads/Opportunities/Properties — and it is written ONLY by the Broker Protection
        // pipeline. That is the whole of its meaning.
        //
        // ⚠ THERE USED TO BE A SECOND, UNRELATED GROUPING ON Opportunity, WHICH IS WHY THIS WARNING
        // IS HERE AT ALL. It answered a DIFFERENT question — "which SELLER'S deal bundle is this part
        // of?" — a MANUAL grouping of several deals under one LOI, anchored by an Opportunity
        // self-lookup and flagged by its own stage on the Acquisitions path. It was dormant for its
        // entire life (no automation ever read or wrote it) and it is now RETIRED outright: the stage
        // value, the path step, the funnel stage list and the FLS grants went in phases A1/A2 of the
        // Portfolio Deal rename, and the Opportunity fields themselves in phase A3.
        //
        // 🔴 THE SURVIVING RULE IS ABOUT THE QUESTIONS, NOT ABOUT THE FIELD NAMES. "Which email routed
        // this record" and "which seller's bundle is this deal in" are different facts, from different
        // sources (a pipeline versus a human), with different lifetimes. If a seller-bundle
        // requirement ever comes back it must get its OWN new field — it must never be satisfied by
        // widening, overloading or cross-populating THIS one, whatever this one happens to be called
        // by then. NO AUTOMATED TEST CAN DETECT THAT REPURPOSING: this comment and ARCHITECTURE.md
        // §1/§2 (residual R1) are the only control. Decision A2, user-directed.
        //
        // 🔴 "WHATEVER THIS ONE HAPPENS TO BE CALLED BY THEN" HAS NOW CASHED IN, AND THE RESULT IS
        // THE MOST DANGEROUS STATE THIS COMMENT HAS EVER GUARDED. On 2026-08-18, phase B4 renamed
        // this field from `Property_Package__c` to `Portfolio_Deal__c` — i.e. the SURVIVING field now
        // carries the very words the RETIRED seller-bundle concept was known by (its stage value was
        // literally "Portfolio Deal"). Anyone reading only the API name will conclude the two were
        // merged. THEY WERE NOT. The retired concept was deleted in A1-A3, and its name was reused
        // for this one precisely because it had become free. So the name is now ACTIVE EVIDENCE FOR
        // THE WRONG CONCLUSION rather than neutral, and this paragraph — not the name, and not any
        // test — is the only thing standing between a future reader and a repurposing that would look
        // like a natural fit. A seller-bundle requirement still gets its own new field.
        o.Portfolio_Deal__c = l.Portfolio_Deal__c;

        // D-f (approved at Gate 1, 2026-08-03) — NAME THE DEAL AFTER THE PROPERTY.
        // The platform derives Opportunity.Name from Lead.Company, which for an email-born deal
        // is either 'Unknown - Via Email' or (after the S4 prompt rule) the broker's FIRM — so
        // every deal from one firm would share one plausible-looking name. Naming from the
        // property makes the deal identifiable. Post-convert only: LeadConvertActionService and
        // Database.LeadConvert.setOpportunityName are untouched. When the lead carries neither a
        // property name nor an address we leave Name unassigned, which preserves whatever the
        // platform derived rather than blanking a required field.
        String dealName = clip(
            firstNonBlank(new List<String>{ l.Property_Name__c, l.Property_Address__c }),
            OPPORTUNITY_NAME_MAX
        );
        if (dealName != null) {
            o.Name = dealName;
        }
    }

    /**
     * Builds (does not insert) the Property for a converted lead, copying the fields the
     * lead carries — the address block, the seller's asking terms, the market links, and
     * (S1) the PHYSICAL property facts the extraction pipeline pulled from the email.
     * Asset type is only set when the lead's value exists on Property's restricted picklist,
     * so an unexpected value can't fail the insert.
     */
    private static Property__c buildProperty(Lead l) {
        String address = propertyAddress(l);
        // NAME PRECEDENCE (S1): a marketing name beats the address. Previously the address always
        // won, so a named asset converted as "1400 Royal Lane, Dallas TX" instead of "Orion
        // ParkView". The address is still on Address__c and on the Property tab, so nothing
        // becomes unfindable — but conversion-born Property names DO read differently from here
        // on, and existing records are deliberately not back-filled.
        String name = firstNonBlank(new List<String>{
            l.Property_Name__c, l.Property_Address__c, l.Street, l.Company, l.Name
        });
        if (name == null) {
            name = 'Property';
        }
        name = clip(name, PROPERTY_NAME_MAX);

        Property__c p = new Property__c();
        p.Name = name;
        p.Address__c = address;
        // ── WS3 (2026-08-30) — THE REUSE KEY. THIS METHOD IS THE ONLY WRITER IN THE APPLICATION. ──
        // 🔴 IT MUST BE `PropertyMatchingService.normalizeAddress`, CALLED — never a second
        // implementation of it, however small. That method is the SOLE definition of the key, it is
        // regex (`[^a-z0-9\s]` -> ' ', collapse, trim), and the same call produces
        // `Property_Registry__c.Property_Key__c` on the broker-protection side. A private copy here
        // would agree with it today and diverge the first time either is touched, at which point
        // the same building keys two ways: the reuse lookup misses, a duplicate Property is created,
        // and NOTHING ANYWHERE REPORTS IT — the org simply goes back to the pre-WS3 behaviour while
        // the tests, which use one path, stay green. P14 also rules out the declarative alternative:
        // Salesforce formulas have no regex, so this cannot be a formula field.
        //
        // ⚠ A BLANK ADDRESS LEAVES THE FIELD NULL, WHICH IS NOT THE SAME AS ''. `normalizeAddress`
        // returns '' for blank input, and an empty key stored on every addressless Property would
        // make them all match each other — every addressless deal in the org collapsing onto one
        // "building". Branch (c) of the routing tree produces addressless Leads, so this is live.
        //
        // ZERO SOQL, ZERO DML: a pure in-memory string transform on a record already in the list
        // `createProperties` inserts with ONE statement. The header's SOQL change is the LOOKUP in
        // `createProperties`, not this line.
        String normalized = PropertyMatchingService.normalizeAddress(address);
        p.Normalized_Address__c = String.isBlank(normalized) ? null : normalized;
        p.City__c = l.City;
        p.State__c = l.State;
        p.Zip__c = l.PostalCode;
        // The seller's stated asking terms carried on the lead become the Property's asking terms.
        p.Asking_Price__c = l.Guidance_Price__c;
        p.Cap_Rate_Asking__c = l.Guidance_Cap_Rate__c;
        p.Placer_URL__c = l.Placer_AI_Link__c;
        p.CoStar_URL__c = l.CoStar_Link__c;
        p.Asset_Type__c = picklistValueOrNull(l.Asset_Type__c, assetTypeValues());

        // ── S1: physical property facts, carried from the lead ──────────────────────────────
        // Existing Property fields whose semantics already match the lead's, extended rather
        // than duplicated (Square_Footage__c is documented as building GLA; Annual_NOI__c is the
        // §1 rule-5 periodic-amount name for NOI).
        p.Square_Footage__c = l.Building_SF__c;
        p.Annual_NOI__c = l.NOI__c;
        p.Year_Built__c = l.Year_Built__c;
        // New Property fields mirroring their lead sources exactly.
        p.Unit_Count__c = l.Unit_Count__c;
        p.Occupancy_Pct__c = l.Occupancy_Pct__c;   // the SUBJECT asset's stated occupancy —
                                                   // never Occupancy_Rate_Market__c, which is the
                                                   // Placer/CoStar market benchmark.
        p.Year_Renovated__c = l.Year_Renovated__c;
        p.Lot_Size_Acres__c = l.Lot_Size_Acres__c;
        p.WALT_Years__c = l.WALT_Years__c;
        p.ADR__c = l.ADR__c;
        p.Zoning__c = l.Zoning__c;
        p.Seller_Entity__c = l.Seller_Entity__c;
        // The multi-property PORTFOLIO DEAL, carried forward (2026-08-17; field renamed from
        // Property_Package__c in phase B4, 2026-08-18). The Property is the third and last member of
        // the grouping's one-to-many, and it is the member that makes the grouping legible on the
        // Portfolio_Deal__c record page: three Properties from one email, side by side.
        // ZERO SOQL and ZERO DML — this record is already in the list `createProperties` inserts
        // with ONE statement, so the governor contract in the class header is UNCHANGED. See
        // applyDealFields above for the ONE question this lookup answers ("which inbound broker email
        // routed this record?"), why a seller-bundle meaning must never be poured into it, and why
        // the field's NEW name makes that mistake MORE tempting rather than less.
        p.Portfolio_Deal__c = l.Portfolio_Deal__c;
        // ⚠ NEVER WRITE Property__c.Lot_Size__c HERE. It is SQUARE FEET, entered from the
        // Offering Memorandum; we hold ACRES only (LLMExtractionParser canonicalizes lot_size_sf
        // into acres and stores nothing else). Computing SF = acres x 43,560 would derive one
        // number from another — forbidden by this module's anti-hallucination contract — and
        // would overwrite an analyst's OM figure with a machine estimate.
        return p;
    }

    /**
     * S2 — put each converted Contact on its new Opportunity as the primary Broker.
     *
     * READ-THEN-WRITE, never a blind insert: standard conversion has already created a primary
     * OpportunityContactRole for this Contact with a blank Role (see the class header). One
     * selector read for the whole converted set, then ONE bulk statement per partition —
     * SOQL 2 of 3, DML 3 (≤4), constant regardless of batch size. The partition is deliberate
     * and is explained in the class header: upsert would be one statement instead of two, but
     * its support on this standard junction is the one unknown in this method, and a DML failure
     * raised inside a Lead after-update trigger rolls back the entire conversion.
     *
     * The 'Broker' role value is DESCRIBE-GUARDED for the same reason the field picklists are:
     * OpportunityContactRole.Role is driven by the ContactRole standard value set, so a value
     * missing from the target org would throw at runtime — and here that would roll back the
     * whole conversion, not just the role. When the value is absent we skip the step entirely
     * (no read, no write) and conversion proceeds untouched; the visible symptom is a broker with
     * no role on the Contact Roles list, which is exactly what the persona UAT checks.
     */
    private static void stampBrokerContactRoles(Map<Id, Lead> oppToLead) {
        if (!contactRoleValues().contains(BROKER_ROLE)) {
            return;
        }
        Map<Id, Id> oppToContactId = convertedContactByOpportunity(oppToLead);
        if (oppToContactId.isEmpty()) {
            return;
        }
        Map<String, OpportunityContactRole> existingByPair = existingRolesByPair(oppToContactId.keySet());

        // PARTITION by whether conversion already left us a row. Doing this in the loop — rather
        // than handing one mixed list to upsert — is what keeps every DML statement below an
        // operation the platform certainly supports on this junction.
        List<OpportunityContactRole> roleUpdates = new List<OpportunityContactRole>();
        List<OpportunityContactRole> roleInserts = new List<OpportunityContactRole>();
        for (Id oppId : oppToContactId.keySet()) {
            Id contactId = oppToContactId.get(oppId);
            OpportunityContactRole prior = existingByPair.get(pairKey(oppId, contactId));
            if (prior == null) {
                roleInserts.add(new OpportunityContactRole(
                    OpportunityId = oppId,
                    ContactId = contactId,
                    Role = BROKER_ROLE,
                    IsPrimary = true
                ));
                continue;
            }
            // Update the row conversion already made: name the role, and claim primary only when
            // it is not already primary (Salesforce allows one primary per Opportunity, so
            // re-asserting it is pointless churn that could demote a deliberate choice).
            OpportunityContactRole edit = new OpportunityContactRole(Id = prior.Id, Role = BROKER_ROLE);
            if (prior.IsPrimary != true) {
                edit.IsPrimary = true;
            }
            roleUpdates.add(edit);
        }
        // ONE bulk statement per partition, each isEmpty()-guarded so an empty list never spends a
        // DML. The update comes first because it is the ordinary path: conversion creates the row,
        // so roleInserts is normally empty and this method normally costs exactly one statement.
        // allOrNone = false on both, for the same reason as the Property insert — one bad role row
        // must never roll back a completed conversion.
        if (!roleUpdates.isEmpty()) {
            Database.update(roleUpdates, false);
        }
        if (!roleInserts.isEmpty()) {
            Database.insert(roleInserts, false);
        }
    }

    /**
     * Converted Opportunity Id -> converted Contact Id, skipping any lead that produced no
     * Contact. LastName is required on a Lead so a Contact is always produced in practice, but the
     * null check costs nothing and keeps the pairing total.
     */
    private static Map<Id, Id> convertedContactByOpportunity(Map<Id, Lead> oppToLead) {
        Map<Id, Id> oppToContactId = new Map<Id, Id>();
        for (Id oppId : oppToLead.keySet()) {
            Id contactId = oppToLead.get(oppId).ConvertedContactId;
            if (contactId != null) {
                oppToContactId.put(oppId, contactId);
            }
        }
        return oppToContactId;
    }

    /**
     * The contact-role rows that already exist on the converted Opportunities, keyed by
     * (Opportunity, Contact). ONE selector call for the whole set — SOQL 2 of 3.
     */
    private static Map<String, OpportunityContactRole> existingRolesByPair(Set<Id> opportunityIds) {
        Map<String, OpportunityContactRole> existingByPair = new Map<String, OpportunityContactRole>();
        for (OpportunityContactRole r : OpportunityContactRoleSelector.selectByOpportunityIds(opportunityIds)) {
            existingByPair.put(pairKey(r.OpportunityId, r.ContactId), r);
        }
        return existingByPair;
    }

    /** Stable composite key for an (Opportunity, Contact) pair. */
    private static String pairKey(Id opportunityId, Id contactId) {
        return String.valueOf(opportunityId) + '|' + String.valueOf(contactId);
    }

    /**
     * Stamp Contact.Broker and Account.Broker_Firm onto the records standard conversion just
     * created (IR segregation, 2026-08-10).
     *
     * WHY THIS EXISTS. Database.convertLead does NOT map record types onto the Contact or the
     * Account — they take whatever is default for the RUNNING USER'S PROFILE. Profiles are
     * .forceignore'd in this repo, so that default is unverifiable from source and can differ
     * per persona. Once Account OWD is Private, an Account on the wrong record type (or none)
     * matches no sharing rule and takes its Contacts with it, because Contact is
     * ControlledByParent. Deterministic beats depending on a file we cannot read.
     *
     * GOVERNOR CONTRACT — this raises the class budget from 3 DML to ≤5, and that was a
     * deliberate decision, not drift (see the class header). Both statements are
     * isEmpty()-guarded and both are CONSTANT IN BATCH SIZE, which is the property that
     * actually matters: one statement for every converted Contact in the chunk, one for every
     * converted Account, never one per record. A matched Account (LeadConvertMatchService
     * reusing an existing broker firm) is already stamped from the Task 3 backfill, so the
     * ordinary repeat-broker path writes fewer rows — but the statement count is what is
     * pinned, so the contract states the worst case.
     *
     * Both use allOrNone = false for the same reason the Property insert does: a failure to
     * stamp a record type must not roll back the structural RecordTypeId / Property__c link on
     * the Opportunity, which `update updates` guarantees all-or-none above.
     *
     * ═══ FIX ROUND 1 (2026-08-10) — SUPERSEDED, WAS A MISDIAGNOSIS. SEE THE 2026-08-17 ═══
     * ═══ CORRECTION BELOW FOR THE REAL ROOT CAUSE AND FIX. ═══
     * conversionStampsBrokerRecordTypesOnContactAndAccount failed with "Actual: null" after
     * deploy. The fix-round investigation below concluded this was a permission-set
     * provisioning gap on DPEG_Admin_Access and that "no code change here can fix it." Three
     * later, independently-measured repo facts falsify that conclusion:
     *   1. DPEG_Admin_Access.permissionset-meta.xml (lines ~389-410) carries a 2026-08-14
     *      re-measurement: a live retrieve from usman-dpeg found all six IR-segregation
     *      recordTypeVisibilities entries already present and live, exactly once, all
     *      visible=true. The "grant never landed" premise below was itself wrong.
     *   2. TestDataFactoryTest.factoryStampsAcquisitionSideRecordTypes asserts Lead
     *      .Acquisition_Broker, Account.Broker_Firm and Contact.Broker all stamp successfully on
     *      INSERT for the same principal — impossible if isAvailable() were false for it.
     *   3. TestDataFactory.cls (lines ~313-319) documents the opposite finding in writing:
     *      isAvailable() returns true for the admin test-running user for all three record
     *      types.
     * The paragraph below is left in place, struck through in spirit, purely as a record of the
     * mistaken hypothesis — do not act on it. Do NOT redeploy DPEG_Admin_Access hoping to fix
     * this; that file replaces its entire fieldPermissions set on every deploy and this was
     * never what was broken there.
     *
     * ═══ ORIGINAL (WRONG) FIX ROUND 1 TEXT, PRESERVED FOR HISTORY ═══
     * Reproduced live via a savepoint-wrapped anonymous-Apex probe against usman-dpeg (rolled
     * back, no permanent org change) rather than by inspection:
     *   - recordTypeId(Contact.SObjectType, 'Broker') and recordTypeId(Account.SObjectType,
     *     'Broker_Firm') both resolve non-null Ids, but Schema.RecordTypeInfo.isAvailable()
     *     returns FALSE for both, for the exact principal every Apex test and anonymous
     *     execution runs as in this org (usman.khan.dpeg@avanzasolutions.com, System
     *     Administrator profile, WITH DPEG_Admin_Access assigned).
     *   - Forcing the identical Database.update the guard would otherwise skip confirms
     *     isAvailable() is telling the truth, not lying: it fails with
     *     INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY, "invalid record type" (the update path)
     *     and INVALID_CROSS_REFERENCE_KEY, "Record Type ID... isn't valid for the user" (the
     *     insert path) — the same shape TestDataFactory.recordTypeId's header already documents
     *     for this org.
     *   - ConvertedContactId / ConvertedAccountId ARE populated correctly at this point (verified
     *     by direct read-back), and nothing runs afterward to clear a stamp that never landed —
     *     ruling out hypotheses 2-4 the fix-round brief asked to check first.
     *   - CONCLUDED (WRONGLY — see the correction above): a read-only metadata retrieve of the
     *     LIVE org copy of DPEG_Admin_Access was reported to be missing the six IR-segregation
     *     recordTypeVisibilities entries. A later, independent 2026-08-14 re-measurement of the
     *     same org found them present. Two same-day-class "measured retrieves" reaching opposite
     *     conclusions is itself the lesson: re-verify a live-org measurement before writing
     *     "confirmed" into a comment, especially when the conclusion is "no code change can fix
     *     this."
     *
     * ═══ REAL ROOT CAUSE (measured 2026-08-17, see conversionStampsBrokerRecordTypesOnContact ═══
     * ═══ AndAccount's actual failure and Account.Record_Type_Is_Immutable) ═══
     * This IS an Apex/validation-rule interaction, not a provisioning gap. The Account write
     * below is an UPDATE (isAvailable() was true all along; recordTypeId() returned a real,
     * usable Id): Database.convertLead does not map record types onto the Account it creates,
     * so this method updates the already-created Account's RecordTypeId afterward. That trips
     * Account.Record_Type_Is_Immutable (objects/Account/validationRules/), which blocks
     * ISCHANGED(RecordTypeId) on any existing row — it cannot distinguish this deliberate,
     * one-time post-conversion stamp from an unrelated later reparenting, because both look
     * identical to the formula. Database.update(accountUpdates, false) — deliberate, see below —
     * swallows the resulting failure silently, so RecordTypeId stayed null and the test's Account
     * assertion failed while its earlier Contact assertion (a plain Contact UPDATE, no matching
     * rule on Contact) passed. That asymmetry is what ruled out a visibility/provisioning
     * explanation in the first place: a missing record-type grant would have failed the Contact
     * assertion too.
     *
     * THE FIX: a custom permission, exactly as Record_Type_Is_Immutable's own comment prescribes
     * ("If an exemption is ever needed, add a custom permission and gate on $Permission — never
     * widen the rule itself"). Lead_Convert_Account_RecordType_Stamp
     * (force-app/main/default/customPermissions/) is gated into the rule's formula and granted
     * only to Lead_Stage_Actions_Access (the real conversion-triggering population) and
     * DPEG_Admin_Access (the principal this class's own tests and ad hoc admin conversions run
     * as). See the validation rule's and the custom permission's own in-file comments for the
     * full trace. No change to this method or its DML shape was needed or made.
     *
     * ═══ HOW A SKIPPED STAMP BECOMES VISIBLE ═══ (the fix-round brief's "think carefully" ask)
     * allOrNone = false is kept for the reason stated above; a hard throw here would take down
     * every conversion in the chunk over a record-type problem unrelated to the deal itself — the
     * same reasoning that keeps the Property insert non-blocking. Silently unstamped can never
     * become PERMANENTLY invisible, though, because two things are already true and neither is
     * new machinery:
     *   1. conversionStampsBrokerRecordTypesOnContactAndAccount is exactly the read-back
     *      assertion this class's own FLS POSTURE section (above) already mandates for a
     *      not-obviously-a-bug blank field — "query the row directly to tell the two apart." It
     *      is what caught this gap the moment the code reached a real org, before any user did.
     *   2. There is no sanctioned way to make an in-transaction signal LOUDER without either
     *      violating this repo's "no System.debug in production code" rule or reintroducing the
     *      unconditional-throw failure mode this guard exists to prevent (ARCHITECTURE.md §2's
     *      automation-path exception; the same ContentPublication-shaped hazard TestDataFactory's
     *      recordTypeId() header already cites). The correct lever is therefore OPERATIONAL, not
     *      code: re-run this test (or the UAT persona check the FLS POSTURE paragraph already
     *      prescribes) after any permission-set deploy that touches record-type visibility, and
     *      treat a null RecordType.DeveloperName read-back as "provisioning gap," never as "the
     *      stamp code is broken."
     */
    private static void stampConvertedPartyRecordTypes(List<Lead> convertedLeads) {
        Id contactRt = recordTypeId(Contact.SObjectType, 'Broker');
        Id accountRt = recordTypeId(Account.SObjectType, 'Broker_Firm');

        List<Contact> contactUpdates = new List<Contact>();
        List<Account> accountUpdates = new List<Account>();
        Set<Id> seenAccountIds = new Set<Id>();

        for (Lead l : convertedLeads) {
            if (contactRt != null && l.ConvertedContactId != null) {
                contactUpdates.add(new Contact(Id = l.ConvertedContactId, RecordTypeId = contactRt));
            }
            // Several Leads can converge on ONE Account (Smart Lead Conversion reuses a firm),
            // and a duplicate Id in one DML statement throws DUPLICATE_VALUE.
            if (accountRt != null && l.ConvertedAccountId != null && seenAccountIds.add(l.ConvertedAccountId)) {
                accountUpdates.add(new Account(Id = l.ConvertedAccountId, RecordTypeId = accountRt));
            }
        }

        if (!contactUpdates.isEmpty()) {
            Database.update(contactUpdates, false);
        }
        if (!accountUpdates.isEmpty()) {
            Database.update(accountUpdates, false);
        }
    }

    /**
     * The Id of a record type by developer name, or null when it does not exist in this org or
     * is not available to the running user. A describe, not a query — it costs no SOQL, so the
     * SOQL contract stated in the class header is unchanged. Guarded on isAvailable() (not just non-null)
     * because this is a USER-INITIATED path (conversion), unlike the automation-path helpers in
     * EmailToLeadService / TestDataFactory that guard on null only — see ARCHITECTURE.md §2's
     * WITH SYSTEM_MODE automation-path table and the 2026-08-10 measured finding that record
     * type visibility is enforced on Apex DML unconditionally.
     */
    private static Id recordTypeId(Schema.SObjectType sobjType, String developerName) {
        Schema.RecordTypeInfo info = sobjType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    private static String firstNonBlank(List<String> values) {
        for (String v : values) {
            if (String.isNotBlank(v)) {
                return v;
            }
        }
        return null;
    }

    /** Truncates to a field's maximum length; null in, null out. */
    private static String clip(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
    }

    /** The lead's value when the target picklist actually offers it, otherwise null. */
    private static String picklistValueOrNull(String value, Set<String> allowedValues) {
        return (String.isNotBlank(value) && allowedValues.contains(value)) ? value : null;
    }

    /**
     * Active values on any picklist, so we never push a value a restricted picklist rejects.
     * Generalized from the original assetTypePicklistValues() when S1 added two more restricted
     * picklist writes — see the class header for why guarding at source is what lets
     * `update updates` stay all-or-none. getDescribe() is a describe call, not a query: it
     * consumes no SOQL limit, so calling it once per picklist per invocation is free.
     *
     * 🔴 THIS HELPER READS THE FIELD DESCRIBE, WHICH IS BLIND TO THE RECORD-TYPE VALUE SUBSET.
     * A value that is active on the field but absent from the Opportunity Land/Retail record
     * types PASSES this guard and is then REFUSED at the DML layer with
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST — which rolls back the ALL-OR-NONE `update updates`
     * for EVERY Lead in the chunk, structural fields included, and names a picklist rather than a
     * record type in the error. Measured on usman-dpeg 2026-08-31: a Retail-typed Opportunity
     * insert carrying 'Hospitality' was refused with exactly that error while the field describe
     * reported the value active.
     *
     * `Asset_Type__c` (added 2026-08-31) is the FIRST guarded picklist in this class whose
     * record-type subset is a real constraint. `Sale_Process__c`, `Parse_Confidence__c` and
     * `Listing_Status__c` carry NO picklistValues block in either record-type file, so they are
     * unconstrained by record type and the field describe is sufficient for them.
     *
     * ⚠ DO NOT "HARDEN" THIS HELPER TO BE RECORD-TYPE-AWARE. It looks like the robust fix and it
     * is not: it would trade a LOUD, correct rollback for a SILENT drop on the very field the
     * conversion was asked to populate, recreating the original defect invisibly and with no
     * error anywhere. Keep the field value set and BOTH record-type blocks in lockstep instead —
     * that is the control. (Design decision, agent-output/gap-fixes-design.md §1.5 and §9 item 2.)
     */
    private static Set<String> activePicklistValues(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                values.add(e.getValue());
            }
        }
        return values;
    }
}
