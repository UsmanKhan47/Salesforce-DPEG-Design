/**
 * Selector for the standard OpportunityContactRole junction. Encapsulates ALL SOQL against
 * OpportunityContactRole per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * ⚠ THIS IS THE FIRST OpportunityContactRole SOQL — AND THE FIRST OpportunityContactRole
 * HANDLING OF ANY KIND — IN THE APPLICATION. Before this class there was zero
 * OpportunityContactRole code anywhere in force-app/main/default/classes (verified 2026-08-03).
 * Every future read belongs here; do not inline one.
 *
 * Consumers:
 *   • LeadConvertService.stampConvertedOpportunities -> selectByOpportunityIds (Conversion
 *     Enrichment S2: find the OpportunityContactRole standard lead conversion ALREADY created,
 *     so the service can UPDATE it to Role = 'Broker' instead of inserting a duplicate broker
 *     row and a second primary). Internal, user-initiated path — USER_MODE.
 *
 * ═══ WHY A READ EXISTS AT ALL — THE POINT OF THIS SELECTOR ═══
 * Standard lead conversion creates an OpportunityContactRole for the converted Contact with
 * IsPrimary = true and a BLANK Role. A blind insert of a second "Broker" row would therefore
 * produce two rows for one Contact and a second primary on the same Opportunity. This query is
 * what makes the caller's write a read-then-write (update-or-insert) rather than a blind insert,
 * and what makes it idempotent if that path ever re-runs. See LeadConvertService's OCR section.
 *
 * ═══ BULK SHAPE IS A CONTRACT ═══
 * LeadConvertService must stay at exactly **2 SOQL and 3 DML (≤4) per invocation regardless of
 * batch size** — this class contributes the second SOQL, ONCE, for the whole converted set. (The
 * DML bound is 3 in the ordinary case and 4 only in a batch that mixes deals with and without a
 * conversion-created role row; see that class's header for why the write is partitioned rather
 * than a single upsert.) It is
 * called with a Set<Id> of every converted Opportunity in the transaction chunk and returns every
 * matching row in one query. Never call it per record, and never add a query to this class that a
 * caller would have to run in a loop. `LeadConvertServiceTest.
 * bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities` asserts that bound at 251
 * conversions (two convertLead chunks, so the service — and this query — fires twice).
 *
 * ── MODE ──────────────────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector). OpportunityContactRole has
 * no sharing model of its own — access follows the parent Opportunity — so in practice this
 * scopes to Opportunities the running user can see. That is correct here: the caller is stamping
 * an Opportunity the running user just created by converting a Lead.
 *
 * `WITH USER_MODE` (API 67), the §2 default. This is an interactive, user-initiated read (a user
 * clicking Convert on a Lead), not the guest/automation path that earns SYSTEM_MODE in
 * LeadSelector.GuestReads / EmailThreadGuardService, so no SYSTEM_MODE justification exists.
 *
 * ⚠ USER_MODE THROWS, it does not degrade. OpportunityContactRole.Role and IsPrimary ARE
 * FLS-permissionable, so a running user without Read on them raises System.QueryException rather
 * than returning rows with those fields null. The caller runs inside an after-update trigger on
 * Lead, so an uncaught throw here would roll back the conversion. LeadConvertService therefore
 * treats the OCR step as fail-soft and catches it — see the OCR section of its header. Do not add
 * a caller that assumes this cannot throw.
 *
 * @see force-app/main/default/classes/LeadConvertService.cls (sole consumer)
 * @see force-app/main/default/classes/AccountSelector.cls (reference pattern in this repo)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls (canonical template)
 */
public with sharing class OpportunityContactRoleSelector {

    /**
     * Every OpportunityContactRole on the supplied Opportunities — backs LeadConvertService's
     * read-then-write of the Broker role.
     *
     * SCOPED BY OPPORTUNITY, NOT BY (Opportunity, Contact) PAIR, DELIBERATELY. A pair-scoped
     * query would need either a compound bind (not expressible in one SOQL statement) or one
     * query per pair, which is the exact per-record query the 2-SOQL contract forbids. Returning
     * every role row on the converted Opportunities costs nothing extra — a freshly converted
     * Opportunity carries exactly one — and lets the caller key them into a Map itself.
     *
     * ContactId IS SELECTED BECAUSE IT IS THE MATCH KEY. The caller pairs each converted Lead's
     * ConvertedContactId with its ConvertedOpportunityId; without ContactId it could not tell
     * "the row for our Contact" from "a role somebody added for a different Contact".
     *
     * IsPrimary IS SELECTED SO THE CALLER CAN AVOID A NEEDLESS WRITE. Salesforce permits one
     * primary per Opportunity, so re-asserting IsPrimary = true on a row that already has it is
     * pointless churn; the caller only sets it when it is not already true.
     *
     * No ORDER BY: the caller keys the rows into a Map by (OpportunityId, ContactId), so row order
     * carries no meaning. No LIMIT: this is a bulk read for N Opportunities at once and a LIMIT
     * would silently drop other Opportunities' rows.
     *
     * @param opportunityIds Opportunities whose contact roles are wanted (typically every
     *                       Opportunity created by the conversions in this transaction chunk);
     *                       null or empty returns an empty list WITHOUT querying, so callers pay
     *                       no SOQL for an empty key set.
     * @return Matching rows (Id, OpportunityId, ContactId, Role, IsPrimary); an empty list when
     *         the input is null/empty or nothing matches (never null).
     * @throws System.QueryException when the running user lacks Read on OpportunityContactRole or
     *         on the selected fields (USER_MODE). Deliberately left to propagate — the caller owns
     *         the fail-soft decision.
     * @example
     * List<OpportunityContactRole> roles =
     *     OpportunityContactRoleSelector.selectByOpportunityIds(new Set<Id>{ oppId });
     */
    public static List<OpportunityContactRole> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<OpportunityContactRole>();
        }
        return [
            SELECT Id, OpportunityId, ContactId, Role, IsPrimary
            FROM OpportunityContactRole
            WHERE OpportunityId IN :opportunityIds
            WITH USER_MODE
        ];
    }
}
