/**
 * Selector for Opportunity. Encapsulates ALL SOQL against Opportunity per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers:
 *   - OpportunityFunnelController (8 relocated statements: funnel counts, 90-day
 *     outcome counts, top-by-price list, open-pipeline aggregate, deal-type counts)
 *   - OpportunityDocStatusController (Primary_* reference read for the deal card)
 *   - OpportunityApprovalController (stage read inside the no-applicable-process branch)
 *   - StageAdvanceController (stage read for the advance quick actions)
 *
 * MODE — every query is `WITH USER_MODE` (API 67). Opportunity is the only
 * standard-object selector in A1; per the P4 design §5 every standard field
 * selected here (Id, Name, StageName, CloseDate, CreatedDate) is
 * `permissionable=false` and therefore never subject to FLS — USER_MODE cannot
 * throw on it — and every custom field selected (Deal_Type__c, Asset_Type__c,
 * Asking_Price__c, Underwritten_NOI__c, Primary_*__c) is granted by the deployed
 * Acquisition permission sets (P3 custom-field FLS gap = 0). No SYSTEM_MODE path.
 *
 * NOT-FOUND CONTRACT is per-caller and encoded in the method shape:
 *   - read-for-display  -> aggregate / count / list methods return their natural
 *     empty value (empty List, 0, empty aggregate). Never null collections.
 *   - fetch-for-use     -> selectPrimaryRefsById / selectStageRequiredById use a
 *     single-row SOQL assignment. The existing callers assigned the query straight
 *     to a single Opportunity (`Opportunity o = [...]`), so a miss threw the native
 *     System.QueryException. Those methods preserve that exact behavior — they do
 *     not invent a business exception and do not return null.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #16, §4 Skeleton B, §5)
 */
public with sharing class OpportunitySelector {

    /**
     * Count of Opportunities grouped by stage — backs the funnel widget.
     *
     * @return AggregateResult rows with alias `st` (StageName) and `c`
     *         (COUNT(Id)); empty when there are no Opportunities.
     * @example
     * for (AggregateResult ar : OpportunitySelector.countByStage()) { ... }
     */
    public static List<AggregateResult> countByStage() {
        return [
            SELECT StageName st, COUNT(Id) c
            FROM Opportunity
            WITH USER_MODE
            GROUP BY StageName
        ];
    }

    /**
     * Count of Opportunities at a stage whose CloseDate falls within the last N
     * days — backs the recency-scoped outcome cards (PSA / Closed Won / Dead-Pass).
     *
     * Dynamic because `LAST_N_DAYS:n` is a date-literal whose n cannot be a bind
     * variable. `stageName` is passed as a real bind and `days` is coerced through
     * Integer.valueOf, so neither reaches the query as free text — injection-safe.
     *
     * @param stageName Exact StageName to match.
     * @param days      Trailing window in days for CloseDate = LAST_N_DAYS:days.
     * @return The matching Opportunity count (0 when none).
     */
    public static Integer countByStageInLastNDays(String stageName, Integer days) {
        return Database.countQuery(
            'SELECT COUNT() FROM Opportunity ' +
            'WHERE StageName = :stageName AND CloseDate = LAST_N_DAYS:' + Integer.valueOf(days),
            AccessLevel.USER_MODE
        );
    }

    /**
     * Top Opportunities by asking price (largest first, priceless deals last) —
     * backs the "recent / biggest deals" list.
     *
     * @param maxRows Row cap (LIMIT).
     * @return Opportunities ordered by Asking_Price__c DESC NULLS LAST,
     *         CreatedDate DESC; empty when there are no Opportunities.
     */
    public static List<Opportunity> selectTopByAskingPrice(Integer maxRows) {
        return [
            SELECT Id, Name, StageName, Deal_Type__c, Asset_Type__c,
                   Asking_Price__c, Underwritten_NOI__c, CreatedDate
            FROM Opportunity
            WITH USER_MODE
            ORDER BY Asking_Price__c DESC NULLS LAST, CreatedDate DESC
            LIMIT :maxRows
        ];
    }

    /**
     * Open-pipeline rollup — count and summed asking price of Opportunities not in
     * the supplied closed stages. Backs the pipeline snapshot tiles.
     *
     * @param closedStages Stage names to exclude (bound with NOT IN).
     * @return A single AggregateResult row with alias `c` (COUNT(Id)) and `v`
     *         (SUM(Asking_Price__c)); `v` is null when no rows match.
     */
    public static List<AggregateResult> aggregateOpenPipeline(Set<String> closedStages) {
        return [
            SELECT COUNT(Id) c, SUM(Asking_Price__c) v
            FROM Opportunity
            WHERE StageName NOT IN :closedStages
            WITH USER_MODE
        ];
    }

    /**
     * Count of Opportunities of a given deal type — backs the Land / Commercial
     * tiles on the pipeline snapshot.
     *
     * @param dealType Deal_Type__c value to match.
     * @return The matching count (0 when none).
     */
    public static Integer countByDealType(String dealType) {
        return [
            SELECT COUNT()
            FROM Opportunity
            WHERE Deal_Type__c = :dealType
            WITH USER_MODE
        ];
    }

    /**
     * Loads the primary-reference fields for one deal — backs the Deal Summary
     * card's primary-else-latest NDA / LOI / Underwriting resolution.
     *
     * FETCH-FOR-USE: the caller (getDocStatus) has already null-checked the Id and
     * assigned the query to a single Opportunity, so a miss is an error. This
     * preserves that contract via a single-row SOQL assignment that throws the
     * native System.QueryException when the Id resolves to no row.
     *
     * @param opportunityId Opportunity Id to load; must reference an existing row.
     * @return The Opportunity with its Primary_NDA__c / Primary_LOI__c /
     *         Primary_Underwriting__c populated.
     * @throws System.QueryException when no Opportunity matches the Id.
     */
    public static Opportunity selectPrimaryRefsById(Id opportunityId) {
        return [
            SELECT Id, Primary_NDA__c, Primary_LOI__c, Primary_Underwriting__c
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Loads a deal's current stage — backs StageAdvanceController.load (the
     * advance quick actions) and the no-applicable-process branch in
     * OpportunityApprovalController.
     *
     * FETCH-FOR-USE: both callers assigned the query straight to a single
     * Opportunity, so a miss threw System.QueryException. Preserved here via a
     * single-row SOQL assignment. Do not soften to null — the callers dereference
     * StageName immediately.
     *
     * @param recordId Opportunity Id to load; must reference an existing row.
     * @return The Opportunity with Id and StageName populated.
     * @throws System.QueryException when no Opportunity matches the Id.
     */
    public static Opportunity selectStageRequiredById(Id recordId) {
        return [
            SELECT Id, StageName
            FROM Opportunity
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
