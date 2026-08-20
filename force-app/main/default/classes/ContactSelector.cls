/**
 * Selector for the standard Contact object. Encapsulates ALL SOQL against Contact
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * Consumers:
 *   • BrokerAssignmentController.getBrokerOptions -> selectBrokersOrderedByName
 *     (P4, Module B2 — Property Management; internal, USER_MODE).
 *   • BrokerController.getBrokerHub -> selectBrokersRankedByClosedVolume +
 *     selectTopBrokersByActiveListings (P4 cleanup wave F2 — the Broker Hub page;
 *     internal, USER_MODE. Module B missed this class; see the ⚠ FLS note below).
 *   • BrokerPortalController.brokerPriorityFor -> GuestReads
 *     .selectBrokerPriorityByEmailSystem (P4 cleanup wave — guest LWR deal-intake
 *     controller; SYSTEM_MODE + without sharing, nested class below).
 *   • BrokerFirmController.getBrokerFirm -> selectEarliestByAccountId (P4 cleanup
 *     wave G — Opportunity sidebar broker person; internal, USER_MODE, Name-only).
 *   • LeadConvertMatchService.matchForConversion -> selectByEmails (Smart Lead
 *     Conversion, 2026-08-02 — resolves the existing broker Contact so converting a
 *     repeat broker attaches instead of duplicating; internal, USER_MODE). This is
 *     the FIRST outer-class method here that reads the FLS-permissionable
 *     Contact.Email, so it is the first that can throw on FLS for a legitimate
 *     internal user — its caller owns the fail-soft. **Scoped to Contact.Broker
 *     (2026-08-10, IR segregation) — see that method's ApexDoc.**
 *   • DispositionBrokerStampService.stampSelectedBrokerLabel -> selectBrokerLabelsByIds
 *     (off-market broker lookup, 2026-08-20 — derives the denormalised
 *     `Disposition__c.Selected_Broker__c` display string from the chosen broker Contact;
 *     AUTOMATION path, SYSTEM_MODE, see that method's ApexDoc). ⚠ This is the FIRST
 *     SYSTEM_MODE method on the OUTER class — every earlier SYSTEM_MODE read here lived
 *     inside `GuestReads`, so "outer = USER_MODE, inner = SYSTEM_MODE" is no longer a
 *     rule you can read off the class shape. Read the method.
 *   • NdaBuyerStampService.stampBuyerName AND
 *     DispositionOfferBuyerStampService.stampBuyerName -> selectNamesByIds (buyer activity
 *     timeline, 2026-08-20 — derives the denormalised `NDA__c.Counterparty_Name__c` and
 *     `Disposition_Offer__c.Buyer_Name__c` Text from the chosen buyer Contact; AUTOMATION
 *     path, SYSTEM_MODE, see that method's ApexDoc). ⚠ It is the SECOND SYSTEM_MODE method
 *     on the outer class and it is deliberately NOT `selectBrokerLabelsByIds` — the buyer
 *     lookups are UNFILTERED, so that method's "every Id reaching here is a broker" premise
 *     is false for these callers. The full argument is at `selectNamesByIds`; do not merge
 *     the two.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT "BROKER" MEANS IN THIS CLASS — CHANGED 2026-08-20. READ THIS FIRST.
 * ═══════════════════════════════════════════════════════════════════════════════════
 * A broker is a Contact on the `Contact.Broker` RECORD TYPE. It is NO LONGER
 * `Is_Broker__c = true`.
 *
 *     RETRACTED (repo convention: quote it, do not delete it): every "filters the custom
 *     Contact.Is_Broker__c" statement that previously appeared in this header. Four
 *     queries carried that predicate — selectBrokersOrderedByName,
 *     selectBrokersRankedByClosedVolume, selectTopBrokersByActiveListings and
 *     GuestReads.selectBrokerPriorityByEmailSystem — and all four now filter
 *     `RecordType.DeveloperName = 'Broker'`.
 *
 * WHY, MEASURED: on `usman-dpeg`, ZERO Contacts carried `Is_Broker__c = true` while 19
 * sat on the Broker record type. All four queries therefore matched NOTHING org-wide —
 * an application-wide outage (broker options empty, Broker Hub empty, every guest
 * submission defaulted to 'Standard' priority), not a per-feature bug. The form is copied
 * from selectByEmails, which has filtered the record type since 2026-08-10; this change
 * closes the inconsistency that method opened rather than adding a new convention.
 *
 * ⚠ TWO METHODS DELIBERATELY DO NOT FILTER BROKER-NESS AT ALL, and were NOT touched:
 * `selectBrokerLabelsByIds` and `selectNamesByIds`. Each documents at its own declaration
 * why an eligibility term there would convert an ineligible Contact into a SILENT
 * "leave the text unchanged". Do not "make them consistent" with the four above.
 *
 * ⚠ `Is_Broker__c` still exists on Contact and is now UNUSED by this class. It was not
 * deleted, backfilled or de-permissioned — retirement is a separate, deferred task. Do not
 * re-add it as an `AND` term anywhere here: the two populations disagree in this org, so an
 * `AND` reintroduces the zero-row outage.
 *
 * MODE — mixed, per method (each method's ApexDoc restates its own mode):
 *   • selectBrokersOrderedByName uses `WITH USER_MODE` (API 67). Design §5
 *     classifies the standard fields touched here: Name is permissionable=false
 *     (always readable). The query also selects the custom Contact.Broker_Firm__c,
 *     an FLS-controlled custom field granted by the DPEG_Acquisitions permission set
 *     (see the SelectorTest runAs proof). ⚠ CORRECTED 2026-08-10 (IR segregation, Task 6):
 *     DPEG_Acquisitions is NOT the only permset granting it — DPEG_Contact_Edit /
 *     DPEG_Contact_View (Task 2) also grant Contact-field FLS to reach the Contact.Broker
 *     record type, and the SelectorTest runAs fixture itself now assigns both. USER_MODE
 *     therefore enforces the running user's FLS on that custom field, from whichever
 *     permset supplies it.
 *     ⚠ FLS SURFACE SHRANK ON 2026-08-20 BUT DID NOT CLOSE. The retired `Is_Broker__c`
 *     predicate was itself FLS-controlled, so it could throw under USER_MODE; the
 *     replacement `RecordType.DeveloperName` traversal is not a permissionable custom
 *     field and cannot. The remaining USER_MODE exposure on these methods is entirely in
 *     the SELECT LIST, not the WHERE clause. selectByEmails has run this exact traversal
 *     under USER_MODE since 2026-08-10 with a passing runAs proof, so the mode is
 *     unchanged and evidenced, not assumed.
 *   • selectBrokersRankedByClosedVolume and selectTopBrokersByActiveListings use
 *     `WITH USER_MODE`. They select Name (permissionable=false) plus SEVEN custom
 *     Contact fields (Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
 *     Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c)
 *     and filter the Broker record type (plus Active_Listings__c on the second, which is
 *     NOT part of the broker definition and must not be removed with it). Those custom
 *     fields are covered by the P3 blanket "custom-field FLS gap = 0" verdict (design §5)
 *     but are NOT itemised in design §5's Contact FLS table — see the ⚠ DESIGN NOTE below.
 *   • selectByEmails uses `WITH USER_MODE` and is the first OUTER method that reads the
 *     FLS-permissionable Contact.Email; its caller owns the fail-soft (see its ApexDoc).
 *   • selectBrokerLabelsByIds uses `WITH SYSTEM_MODE` (API 67) on the OUTER class —
 *     ARCHITECTURE.md §2's automation-path exception, argued in full at the method. It
 *     stays `with sharing`: SYSTEM_MODE lifts CRUD/FLS and never sharing, and an
 *     unreadable Contact is the correct failure direction here.
 *   • selectNamesByIds uses `WITH SYSTEM_MODE` (API 67) on the OUTER class too, for the same
 *     automation-path reason argued independently at that method — plus one this class has
 *     not carried before: it is reached from a trigger on a DUAL-MODULE object (`NDA__c`)
 *     that fires for principals with no Contact grant at all, and USER_MODE would roll back
 *     THEIR save. It stays `with sharing` for the same reason as its sibling.
 *   • GuestReads.selectBrokerPriorityByEmailSystem uses `WITH SYSTEM_MODE` (API 67)
 *     inside a `without sharing` inner class — the guest Broker-Portal intake path
 *     (see that class's ApexDoc). 🔴 This is the ONLY unauthenticated read in this class,
 *     and the 2026-08-20 definition change takes it from matching ZERO rows to matching the
 *     real broker roster. Its two containment invariants — email-equality scope and a
 *     ONE-FIELD select list — are stated at the method and must not be relaxed.
 *
 * ⚠ SHARING — the broker-priority lookup is BEHAVIOR-PRESERVING WITHOUT SHARING (see
 * the nested `GuestReads` class). The outer ContactSelector stays `with sharing`;
 * only the guest lookup lives in the `without sharing` inner class so it sees the
 * broker Contact regardless of the guest user's sharing — exactly as the original
 * `without sharing` BrokerPortalController inline query did. Under `WITH SYSTEM_MODE`,
 * FLS is bypassed but record-level sharing follows the class keyword; a `with sharing`
 * selector would have silently scoped the lookup to the (minimal, unconfigured) guest
 * sharing and defaulted every broker to 'Standard' priority.
 *
 * ⚠ DESIGN NOTE (flagged to the orchestrator): design §5 characterises the Contact
 * queries as "selects Name only", but two relocated queries genuinely select custom,
 * FLS-controlled fields:
 *   - getBrokerOptions -> selectBrokersOrderedByName selects Broker_Firm__c.
 *     (⚠ 2026-08-20: this read "selects Broker_Firm__c and filters Is_Broker__c". The
 *     predicate half is retracted — the filter is now the non-FLS RecordType traversal, so
 *     Broker_Firm__c in the SELECT list is the whole of this method's FLS exposure.)
 *   - getBrokerHub -> selectBrokersRankedByClosedVolume /
 *     selectTopBrokersByActiveListings select SEVEN custom Broker_* fields and filter
 *     Active_Listings__c. (⚠ 2026-08-20: this read "filter Is_Broker__c /
 *     Active_Listings__c"; only Active_Listings__c remains an FLS-controlled predicate.)
 *     RentRollController/BrokerController were never
 *     in the design's §2 inventory (Module B built BrokerAssignment and missed them),
 *     so those seven fields were never itemised in §5's Contact FLS table — they rely
 *     solely on the P3 blanket "custom-field FLS gap = 0" measurement, not a per-field
 *     check. A running user WITHOUT a permset granting those Contact fields will hit a
 *     USER_MODE QueryException here. See the report.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/TaskSelector.cls (P4 standard-object template)
 * @see agent-output/p4-selector-design.md (§3 #19, §4, §5)
 */
public with sharing class ContactSelector {

    /**
     * Broker Contacts ordered by Name — backs BrokerAssignmentController.getBrokerOptions,
     * which renders each as a "Name · Firm" picklist option. Selects Broker_Firm__c so the
     * caller can build that label; the field set and `ORDER BY Name` mirror the original
     * inline query.
     *
     * ══ 🔴 BROKER DEFINITION MOVED 2026-08-20 — `RecordType.DeveloperName`, NOT `Is_Broker__c` ══
     * RETRACTED, not edited away, because a reader carrying the old predicate needs to see it:
     *
     *     RETRACTED: "Broker Contacts (Is_Broker__c = true) ordered by Name"
     *
     * A broker is now a Contact on the `Contact.Broker` RECORD TYPE. Measured on `usman-dpeg`
     * before the change: ZERO Contacts carried `Is_Broker__c = true` while 19 sat on the Broker
     * record type, so this query — and its three siblings below — matched NOTHING org-wide. That
     * is an application-wide outage restored here, not a refactor.
     *
     * The predicate form is copied EXACTLY from `selectByEmails` below, which has filtered
     * `RecordType.DeveloperName = 'Broker'` since 2026-08-10 (IR segregation). This change closes
     * the inconsistency that method opened; do not invent a second form.
     *
     * ⚠ `Is_Broker__c` STILL EXISTS and is deliberately NOT read here. It is retained, unused, and
     * its retirement is a separate task — see `objects/Contact/fields/Is_Broker__c.field-meta.xml`.
     * Do NOT add it back as an `AND` term: the two populations do not agree in this org, and an
     * `AND` would reintroduce the zero-row outage this change repairs.
     *
     * ⚠ FLS SURFACE SHRANK, BUT DID NOT CLOSE. `Is_Broker__c` (custom, FLS-controlled) has left
     * the WHERE clause, so it can no longer throw under USER_MODE — but `Broker_Firm__c` is still
     * SELECTED and still can. The class header's FLS note stands on the select list, not the
     * predicate.
     *
     * @return Broker-record-type Contacts (Id, Name, Broker_Firm__c) ordered by Name; an empty
     *         list when no broker Contacts exist (never null).
     * @example
     * List<Contact> brokers = ContactSelector.selectBrokersOrderedByName();
     */
    public static List<Contact> selectBrokersOrderedByName() {
        return [
            SELECT Id, Name, Broker_Firm__c
            FROM Contact
            WHERE RecordType.DeveloperName = 'Broker'
            WITH USER_MODE
            ORDER BY Name
        ];
    }

    /**
     * All broker Contacts ranked by Closed_Volume__c — backs BrokerController.getBrokerHub,
     * which uses this both as the full broker list and to derive the header stats (firm count,
     * active-broker count, listing/offer/volume totals). Ordered by Closed_Volume__c DESC NULLS
     * LAST, then Name ASC, and selects the seven Broker_* stat fields, mirroring the original
     * inline query exactly.
     *
     * ══ 🔴 BROKER DEFINITION MOVED 2026-08-20 ══
     *     RETRACTED: "All broker Contacts (Is_Broker__c = true) ranked by Closed_Volume__c"
     * `RecordType.DeveloperName = 'Broker'` is now the definition. The full argument — including
     * why re-adding `Is_Broker__c` as an `AND` term would reintroduce a measured zero-row outage —
     * is at `selectBrokersOrderedByName` above and is not repeated per method.
     *
     * ⚠ THIS IS THE METHOD THE BROKER HUB'S NUMBERS COME FROM. Its result set changes from 0 rows
     * to the org's real broker population, so every header stat on that page changes at the same
     * moment. Expected, and the point of the change.
     *
     * @return Broker-record-type Contacts (Id, Name, and the seven Broker_* fields) ranked by
     *         closed volume; an empty list when no broker Contacts exist (never null).
     * @example
     * List<Contact> brokers = ContactSelector.selectBrokersRankedByClosedVolume();
     */
    public static List<Contact> selectBrokersRankedByClosedVolume() {
        return [
            SELECT Id, Name, Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
                   Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c
            FROM Contact
            WHERE RecordType.DeveloperName = 'Broker'
            WITH USER_MODE
            ORDER BY Closed_Volume__c DESC NULLS LAST, Name ASC
        ];
    }

    /**
     * Top broker Contacts with at least one active listing, ranked for the "top brokers"
     * widget — backs BrokerController.getBrokerHub. Filters the Broker record type AND
     * Active_Listings__c > 0, orders by Active_Listings__c DESC then Closed_Volume__c
     * DESC NULLS LAST, and caps the result at maxRows. Field set matches
     * selectBrokersRankedByClosedVolume so the caller maps both lists identically.
     *
     * ══ 🔴 BROKER DEFINITION MOVED 2026-08-20 ══
     *     RETRACTED: "Filters Is_Broker__c = true AND Active_Listings__c > 0"
     * Argument at `selectBrokersOrderedByName` above.
     *
     * 🔴 `Active_Listings__c > 0` IS NOT PART OF THE BROKER DEFINITION AND MUST SURVIVE. Only the
     * FIRST conjunct moved. This method answers "which brokers have listings to show in the top-
     * brokers widget", and dropping the second term would silently pull zero-listing brokers into
     * a widget whose entire premise is that they have listings — including the seeded 'Northmarq'
     * broker, which exists precisely to prove the exclusion. Its sibling
     * `selectBrokersRankedByClosedVolume` is the unfiltered list; this one is not.
     *
     * @param maxRows Maximum rows to return (the caller's TOP_LIMIT). A null or
     *                non-positive value yields an empty list without querying.
     * @return Up to maxRows broker Contacts with active listings, ranked; an empty list
     *         when maxRows is null/non-positive or no broker has active listings (never null).
     * @example
     * List<Contact> top = ContactSelector.selectTopBrokersByActiveListings(6);
     */
    public static List<Contact> selectTopBrokersByActiveListings(Integer maxRows) {
        if (maxRows == null || maxRows <= 0) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Name, Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
                   Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c
            FROM Contact
            WHERE RecordType.DeveloperName = 'Broker' AND Active_Listings__c > 0
            WITH USER_MODE
            ORDER BY Active_Listings__c DESC, Closed_Volume__c DESC NULLS LAST
            LIMIT :maxRows
        ];
    }

    /**
     * The earliest-created Contact linked to an Account — backs
     * BrokerFirmController.getBrokerFirm, which treats it as the broker person behind
     * the brokerage firm (Account). Selects Id + Name (the caller reads only Name) and
     * orders CreatedDate ASC LIMIT 1, mirroring the original inline query. Added by P4
     * cleanup wave G.
     *
     * MODE — `WITH USER_MODE`. Only Name (permissionable=false) is selected and only
     * the standard AccountId is filtered, so USER_MODE cannot throw an FLS error here
     * (no custom, FLS-controlled field is touched — unlike the broker methods above).
     *
     * READ-FOR-DISPLAY: an Account with no linked Contact is a normal state, so this
     * returns Contact-or-null rather than throwing.
     *
     * @param accountId The firm Account whose broker Contact to read; null-safe.
     * @return The earliest-created Contact (Id, Name) for the Account, or null when
     *         the input is null or the Account has no Contact.
     * @example
     * Contact broker = ContactSelector.selectEarliestByAccountId(accountId);
     */
    public static Contact selectEarliestByAccountId(Id accountId) {
        if (accountId == null) {
            return null;
        }
        List<Contact> contacts = [
            SELECT Id, Name
            FROM Contact
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY CreatedDate
            LIMIT 1
        ];
        return contacts.isEmpty() ? null : contacts[0];
    }

    /**
     * Contacts whose Email exactly matches one of the supplied addresses AND that belong to an
     * Account — backs LeadConvertMatchService's broker match on Lead.Email (Smart Lead
     * Conversion), so converting a repeat broker attaches to the Contact they already are rather
     * than minting a duplicate.
     *
     * INTERNAL PATH, NOT GUEST. This lives on the OUTER class (with sharing, USER_MODE) and is
     * deliberately NOT a sibling of GuestReads.selectBrokerPriorityByEmailSystem below. That one
     * is the public Broker-Portal guest read and is without-sharing/SYSTEM_MODE for reasons that
     * do not apply here: this read runs for a signed-in user clicking Convert on a Lead record.
     * Do not "consolidate" the two — they answer different questions under different trust models.
     *
     * `AccountId != null` IS A FILTER, NOT A DEFENSIVE CHECK. Salesforce requires the conversion
     * target Contact to belong to the Account being converted into (LeadConvert.setContactId is
     * only valid alongside a setAccountId for that Contact's own Account). Excluding orphans in
     * the QUERY means the caller has no special case to forget: an account-less Contact simply
     * never matches, and that Lead takes the ordinary create-a-new-Contact path. Accepted
     * consequence (design L1): a broker whose only Contact has no Account still gets a duplicate.
     *
     * CASE-INSENSITIVITY IS THE PLATFORM'S. SOQL string comparison on Email fields is
     * case-insensitive by default, so `WHERE Email IN :emails` already means "case-insensitive
     * exact". Do NOT add LOWER() — invalid here and unnecessary. The caller still lower-cases its
     * Map keys, because Apex Map keys ARE case-sensitive.
     *
     * ORDERING IS LOAD-BEARING (design D2, oldest-wins), identical to AccountSelector.selectByNames:
     * `CreatedDate ASC, Id ASC` lets the caller take the first row per email as the winner.
     * CreatedDate alone is not a total order (same-transaction rows share it), so `Id ASC` is the
     * tiebreak that keeps the pick deterministic across conversions. No LIMIT — this is a bulk
     * read for N Leads and a LIMIT would drop other emails' rows.
     *
     * MODE — `WITH USER_MODE`. Contact.Email IS FLS-permissionable, so unlike the Name-only
     * methods above this query genuinely CAN throw for a user without read on it. USER_MODE
     * throws rather than degrading; that is handled by the sole caller, which catches
     * QueryException and falls back to no-match so conversion never regresses (see
     * LeadConvertMatchService's fail-soft section). Left to propagate here by design.
     *
     * RECORD TYPE SCOPE (2026-08-10, IR segregation). Restricted to Contact.Broker. The broker
     * and investor populations are disjoint by policy, so this filter changes no behaviour
     * today — it makes the guarantee STRUCTURAL. Without it, one shared email address between
     * a broker and an investor would attach an acquisition deal to an IR Contact and its
     * Investor_Entity Account, which is precisely the boundary this module exists to hold.
     *
     * ⚠ A Contact on the MASTER record type will not match. That is intended and is why the
     * Task 3 backfill is gated on a zero-row query before OWD flips.
     *
     * @param emails Broker email addresses to resolve (the converting Leads' Email values); null
     *               or empty returns an empty list WITHOUT querying.
     * @return Matching Broker-record-type Contacts with an Account (Id, Email, AccountId,
     *         CreatedDate) ordered CreatedDate ASC, Id ASC; an empty list when the input is
     *         null/empty, nothing matches, or the only matches are on a non-Broker record type
     *         (never null).
     * @throws System.QueryException when the running user lacks read on Contact or Contact.Email.
     * @example
     * List<Contact> brokers = ContactSelector.selectByEmails(new Set<String>{ 'broker@firm.com' });
     */
    public static List<Contact> selectByEmails(Set<String> emails) {
        if (emails == null || emails.isEmpty()) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Email, AccountId, CreatedDate
            FROM Contact
            WHERE Email IN :emails
              AND AccountId != null
              AND RecordType.DeveloperName = 'Broker'
            WITH USER_MODE
            ORDER BY CreatedDate ASC, Id ASC
        ];
    }

    /**
     * Name + firm for a set of broker Contacts — backs
     * `DispositionBrokerStampService.stampSelectedBrokerLabel`, which composes the denormalised
     * `Disposition__c.Selected_Broker__c` display string from them so the off-market lookup and the
     * text a human reads on the approval page and the Path step cannot disagree AS A RESULT OF A
     * SAVE THAT CHANGES `Broker__c` (off-market broker lookup, 2026-08-20).
     *
     * ⚠ NOT "can never disagree" (code review W5) — the stamp is keyed on `Broker__c` changing, so a
     * Contact RENAME (editing the broker's own `FirstName`/`LastName`/`Broker_Firm__c` without
     * changing which Contact is selected) never fires the Disposition trigger and leaves
     * `Selected_Broker__c` stale. See `DispositionBrokerStampService`'s class header.
     *
     * ── 🔴 WITH SYSTEM_MODE — automation path, and the failure USER_MODE would cause is not this
     *      feature's failure ──────────────────────────────────────────────────
     * ARCHITECTURE.md §2's exception applies on its own terms rather than by inheritance. This read
     * happens INSIDE A BEFORE-TRIGGER ON `Disposition__c`, on behalf of whoever saved that record.
     * Nobody asked for it, and NOTHING it returns is displayed — the caller derives a string from it
     * and assigns that string in memory.
     *
     * `USER_MODE` THROWS RATHER THAN DEGRADES. A principal without FLS read on
     * `Contact.Broker_Firm__c` would raise `System.QueryException: No such column` — an FLS denial
     * wearing a schema error — which escapes the trigger as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and
     * ROLLS BACK THE USER'S OWN DISPOSITION SAVE. A read added to keep two fields in agreement must
     * not be able to destroy the transaction it was added to. Same argument, same shape, as
     * `DispositionSelector.selectStagesByIds`.
     *
     * ⚠ IT IS NOT MERELY THEORETICAL EVEN THOUGH TODAY'S PERSONAS ARE PROVISIONED. `DPEG_Contact_Edit`
     * and `DPEG_Contact_View` both grant `Broker_Firm__c` today, and the analyst who picks holds one
     * of them — but this trigger fires on EVERY `Disposition__c` write in the org, including writes
     * made by principals who have no Contact grants at all and no business reading brokers. For those
     * principals `Broker__c` has not changed, so this method is never called; SYSTEM_MODE is what
     * makes that "never called" the only thing standing between them and a rolled-back save, instead
     * of also depending on a grant they legitimately lack.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE. `SYSTEM_MODE` lifts CRUD and
     * FLS, NEVER sharing, and this outer class stays `with sharing`. The `GuestReads` inner class
     * below is NOT the pattern to copy here: there, a filtered-out row silently defaulted every
     * broker to 'Standard' priority with nothing to notice. Here, a Contact the running user cannot
     * SEE is simply absent from the result, and the caller then leaves `Selected_Broker__c`
     * UNCHANGED rather than blanking it — a visible, self-healing residual on a record whose lookup
     * the user could not have set in the first place. **Do not add a `without sharing` inner class
     * for this.**
     *
     * ⚠ `Name` IS THE COMPOUND FIELD AND IS `permissionable = false`, so it is always readable and is
     * not what SYSTEM_MODE is here for. `Broker_Firm__c` is. Do not "simplify" this to FirstName +
     * LastName: `Name` already applies the org's name format, and the caller's 244-character length
     * proof is written against `Name`'s own ≤ 121 ceiling.
     *
     * NO `Is_Broker__c` FILTER, AND THAT IS DELIBERATE. The active, non-optional lookup filter on
     * `Disposition__c.Broker__c` already guarantees every Id reaching here is a broker Contact, and
     * re-testing it in the query would turn a Contact that was later un-flagged into a SILENT
     * "leave the text unchanged" instead of a re-stamp. This method answers "what is this Contact
     * called", not "is this Contact eligible".
     *
     * ⚠ 2026-08-20 — THE ARGUMENT ABOVE IS UNCHANGED; ONLY THE MECHANISM IT NAMES MOVED. The
     * `Disposition__c.Broker__c` lookup filter now tests the `Contact.Broker` RECORD TYPE rather
     * than `Is_Broker__c`, so read "later un-flagged" as "later moved off the Broker record type".
     * 🔴 THIS METHOD WAS DELIBERATELY NOT REPOINTED when its four broker-filtering siblings were.
     * Adding `RecordType.DeveloperName = 'Broker'` here would be exactly the silent-no-stamp bug
     * this paragraph exists to prevent, merely spelled with the new predicate. Do not "make it
     * consistent" with the four above.
     *
     * Bulk-safe: ONE query for the whole set, never one per record.
     *
     * @param contactIds Contact Ids to label; null or empty returns an empty list WITHOUT querying
     *                   (the same contract as `DispositionSelector.selectStagesByIds`).
     * @return Contacts with Id, Name and Broker_Firm__c populated; an empty list when the input is
     *         null/empty or no row is visible to the running user (never null). A row the user
     *         cannot SEE is simply absent — see the sharing note above.
     * @example
     * List&lt;Contact&gt; brokers = ContactSelector.selectBrokerLabelsByIds(brokerIds);
     */
    public static List<Contact> selectBrokerLabelsByIds(Set<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Name, Broker_Firm__c
            FROM Contact
            WHERE Id IN :contactIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * NAME ONLY, for a set of ARBITRARY Contacts — backs BOTH buyer stamp services
     * (`NdaBuyerStampService.stampBuyerName` and
     * `DispositionOfferBuyerStampService.stampBuyerName`), which copy `Contact.Name` straight across
     * onto the denormalised `NDA__c.Counterparty_Name__c` / `Disposition_Offer__c.Buyer_Name__c`
     * Text fields so the buyer lookup and the text a human reads cannot disagree AS A RESULT OF A
     * SAVE THAT CHANGES `Buyer__c` (buyer activity timeline, 2026-08-20).
     *
     * ⚠ NOT "can never disagree" — the stamps are keyed on `Buyer__c` changing, so a Contact RENAME
     * never fires either trigger and leaves the Text stale. See either stamp service's header.
     *
     * ══ 🔴 IT IS A SEPARATE METHOD FROM `selectBrokerLabelsByIds`, AND MERGING THEM WOULD BE WRONG ══
     * The two queries would differ by ONE FIELD, which is exactly the shape that invites a merge.
     * Three reasons not to:
     *   1. THE NAME WOULD LIE. `selectBrokerLabelsByIds` means "label these BROKER Contacts", and its
     *      own ApexDoc rests on a measured premise that is FALSE here: *"The active, non-optional
     *      lookup filter on `Disposition__c.Broker__c` already guarantees every Id reaching here is a
     *      broker Contact."* `NDA__c.Buyer__c` and `Disposition_Offer__c.Buyer__c` are DELIBERATELY
     *      UNFILTERED (design O-5, closed by the user's accepted recommendation — a buyer is
     *      deal-scoped, not a durable role, and there is no `Is_Buyer__c` and no population behind
     *      one). Ids reaching THIS method are arbitrary Contacts and usually not brokers at all.
     *   2. `Broker_Firm__c` WOULD BE DEAD DATA HERE. Neither buyer stamp reads a firm — each copies
     *      ONE field straight across. Selecting a field no caller reads is the "plausible-looking
     *      dead code" this tranche's design explicitly warns against, and on a buyer Contact the
     *      firm is meaningless (blank on every Contact the broker seed script did not create).
     *   3. THE CALLERS' CEILINGS DIFFER AND THE MERGE WOULD HIDE THAT. `Counterparty_Name__c` is
     *      Text(120) and truncates; `Buyer_Name__c` is Text(255) and does not. One shared "labels"
     *      method invites one shared truncation constant, which is the bug.
     * ⚠ Conversely, do NOT re-point `selectBrokerLabelsByIds` at this method either — it needs the
     *   firm and this one must not grow one.
     *
     * ── 🔴 WITH SYSTEM_MODE — automation path, and the failure USER_MODE would cause is not this
     *      feature's failure ──────────────────────────────────────────────────
     * ARCHITECTURE.md §2's exception applies on its own terms rather than by inheritance from the
     * broker sibling. This read happens INSIDE A BEFORE TRIGGER on `NDA__c` or
     * `Disposition_Offer__c`, on behalf of whoever saved that record. Nobody asked for it, and
     * NOTHING it returns is displayed — the caller copies one value into an in-memory field.
     *
     * `USER_MODE` THROWS RATHER THAN DEGRADES. `Name` is a compound field with
     * `permissionable = false`, so FLS on the field itself cannot be the failure — but USER_MODE
     * enforces OBJECT-level read on `Contact` too, and `NdaTrigger` fires on EVERY `NDA__c` save in
     * the org, ACQUISITION NDAs INCLUDED. Neither `DPEG_Disposition_View`/`_Edit` nor either
     * acquisition permission set grants `Contact`; that grant lives in `DPEG_Contact_View` /
     * `DPEG_Contact_Edit`, which are separate members of the two persona permission-set GROUPS. A
     * principal outside those groups — an integration user, a data load, an administrator holding
     * neither — would raise `System.QueryException`, which escapes a before trigger as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and ROLLS BACK THEIR OWN NDA SAVE. A read added to keep
     * two fields in agreement must not be able to destroy the transaction it was added to. Same
     * argument, same shape, as `selectBrokerLabelsByIds` and `DispositionSelector.selectStagesByIds`.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE. `SYSTEM_MODE` lifts CRUD and
     * FLS, NEVER sharing, and this outer class stays `with sharing`. `GuestReads` below is NOT the
     * pattern to copy: there, a filtered-out row silently defaulted every broker to 'Standard'
     * priority with nothing to notice. Here, a Contact the running user cannot SEE is simply absent
     * from the result, and the caller then leaves the Text field UNCHANGED rather than blanking it —
     * a visible, self-healing residual on a record whose lookup the user could not have set in the
     * first place. **Do not add a `without sharing` inner class for this.**
     *
     * ⚠ NO RECORD-TYPE AND NO `Is_Broker__c` FILTER, DELIBERATELY. This method answers "what is this
     * Contact called", not "is this Contact eligible". Adding an eligibility term would turn a
     * Contact that fails it into a SILENT "leave the text unchanged" instead of a stamp.
     *
     * Bulk-safe: ONE query for the whole set, never one per record.
     *
     * @param contactIds Contact Ids to name; null or empty returns an empty list WITHOUT querying
     *                   (the same contract as `selectBrokerLabelsByIds`).
     * @return Contacts with Id and Name populated; an empty list when the input is null/empty or no
     *         row is visible to the running user (never null). A row the user cannot SEE is simply
     *         absent — see the sharing note above.
     * @example
     * Map&lt;Id, Contact&gt; byId = new Map&lt;Id, Contact&gt;(ContactSelector.selectNamesByIds(buyerIds));
     */
    public static List<Contact> selectNamesByIds(Set<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Name
            FROM Contact
            WHERE Id IN :contactIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * Guest-portal anti-abuse Contact reads that MUST run WITHOUT SHARING.
     *
     * `without sharing` — guest-portal read; must see the broker Contact regardless
     * of the site guest user's sharing, which is minimal and unconfigured (P3 guest
     * spike incomplete). Inner classes do NOT inherit the outer class's sharing, so
     * `without sharing` is declared explicitly here; the outer ContactSelector stays
     * `with sharing`. Apex forbids static methods on inner classes, so this is an
     * instance method — call
     * `new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem(...)`.
     *
     * ⚠ PRE-PROMOTION: this preserves the INTENT (broker-priority visible to the
     * guest intake, as the original `without sharing` BrokerPortalController inline
     * query did), but the guest sharing/ownership model itself is still unverified —
     * the P3 guest-sharing spike must be completed before portal promotion.
     */
    public without sharing class GuestReads {

        /**
         * A broker Contact for an email — backs BrokerPortalController.brokerPriorityFor,
         * which copies the broker's priority onto each lead they submit so intake can be
         * worked priority-first. Selects Broker_Priority__c and filters the Broker record
         * type, mirroring the original inline query's field set, LIMIT 1 and email trim.
         *
         * SYSTEM_MODE (API 67) bypasses FLS; the enclosing `without sharing` bypasses
         * record sharing — together reproducing the original all-fields/all-records
         * guest read.
         *
         * ══════════════════════════════════════════════════════════════════════════════
         * 🔴 BROKER DEFINITION MOVED 2026-08-20 — AND THIS IS THE ONE UNAUTHENTICATED
         *    CALLER, SO THE CHANGE IS A TRUST-MODEL CHANGE, NOT ONLY A PREDICATE SWAP
         * ══════════════════════════════════════════════════════════════════════════════
         *     RETRACTED: "Selects Broker_Priority__c and filters the custom Is_Broker__c"
         *
         * MEASURED ON `usman-dpeg` BEFORE THE CHANGE: zero Contacts carried
         * `Is_Broker__c = true`, so this query was a GUARANTEED NO-MATCH — every guest
         * submission silently defaulted to 'Standard' priority. After the swap it matches
         * the org's ~19 real broker Contacts. This is the only place in this change where
         * an UNAUTHENTICATED principal begins receiving a value it currently never
         * receives, so the two properties that bound it are stated here as invariants
         * rather than left to be re-derived:
         *
         *   1. THE PREDICATE IS EMAIL-EQUALITY-SCOPED. A guest gets at most the ONE row
         *      matching an email address they themselves supplied. There is no LIKE, no
         *      prefix match, no wildcard, and no way to enumerate. 🔴 Do not relax
         *      `Email = :trimmedEmail` into anything looser — the whole containment
         *      argument rests on it, and a guest-facing `LIKE` here is an enumeration
         *      oracle over the broker roster.
         *   2. THE SELECT LIST IS ONE FIELD. `Broker_Priority__c` and nothing else. It
         *      was NOT widened alongside the predicate change, deliberately. 🔴 Do not add
         *      Name, Phone, Broker_Firm__c or Id here "while you are in the file": under
         *      SYSTEM_MODE + `without sharing` there is no FLS and no sharing left to stop
         *      any field added to this list from reaching an anonymous caller. Every field
         *      added here is a field published to the internet.
         *
         * ⚠ THE RECORD-TYPE PREDICATE IS STRICTLY STRONGER THAN THE CHECKBOX WAS, not merely
         * different. An Investor Contact with a stray ticked `Is_Broker__c` WOULD have matched
         * the old predicate and leaked an IR Contact's priority to the guest path; it CANNOT
         * satisfy `RecordType.DeveloperName = 'Broker'`, because a Contact has exactly one
         * record type. The IR/Acquisitions boundary this module exists to hold is now
         * structural on this query — the same argument `selectByEmails` makes above.
         *
         * ⚠ THE 6 MASTER-RECORD-TYPE CONTACTS IN THIS ORG DO NOT MATCH EITHER, and that is the
         * correct failure direction: an unmatched guest falls back to 'Standard' priority (see
         * the caller), which is a degraded ranking, never a leak and never a rejected
         * submission.
         *
         * ⚠ "MOST-RECENT" WAS NEVER TRUE AND THE CLAIM IS WITHDRAWN. This ApexDoc said "The
         * most-recent broker Contact for an email"; there is no ORDER BY, so `LIMIT 1` returns
         * an ARBITRARY row when an email is duplicated across broker Contacts — which this org
         * genuinely has (three "Derek Simmons" rows, two of them Broker record type). Behaviour
         * PRESERVED here on purpose: adding an ORDER BY would change which priority a guest
         * receives, which is a product decision outside this change's confirmed scope. Recorded
         * so the next reader does not trust the word "most-recent".
         *
         * @param email The broker's email; matched case-insensitively (SOQL Email semantics)
         *              against Contact.Email after trim. Null/blank returns null.
         * @return A matching Broker-record-type Contact with Broker_Priority__c populated, or
         *         null when the input is blank or no Broker-record-type Contact has that email.
         * @example
         * Contact broker = new ContactSelector.GuestReads()
         *     .selectBrokerPriorityByEmailSystem(email);
         */
        public Contact selectBrokerPriorityByEmailSystem(String email) {
            if (String.isBlank(email)) {
                return null;
            }
            String trimmedEmail = email.trim();
            List<Contact> brokers = [
                SELECT Broker_Priority__c
                FROM Contact
                WHERE Email = :trimmedEmail AND RecordType.DeveloperName = 'Broker'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            return brokers.isEmpty() ? null : brokers[0];
        }
    }
}
