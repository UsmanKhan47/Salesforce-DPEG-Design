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
 *   - ContractExecutionService.handleExecution (PSA-execution handoff: the deal
 *     header + primary contract/LOI figures used to stamp the Opportunity and
 *     seed the Transaction — selectExecutionHandoffByIds)
 *   - CallForOffersStampService (Broker Protection's inbound call-for-offers
 *     branch — selectCallForOffersTargetsByIds; `WITH SYSTEM_MODE`, see MODE below)
 *   - CallForOffersService (the call-for-offers UI surfaces —
 *     selectCallForOffersOpen / selectCallForOffersById, both `WITH USER_MODE`)
 *   - CallForOffersAlertBatch (the daily offer-deadline alert job —
 *     queryCallForOffersAlerts, `WITH SYSTEM_MODE`)
 *   - MarketDataSnapshotService (the underwriting-approval market freeze —
 *     selectMarketSnapshotSourceByIds; `WITH SYSTEM_MODE`, see MODE below)
 *   - TopDealsController (the "Top 5 Largest Deals" home-page card —
 *     selectTopByAmount, `WITH USER_MODE`)
 *
 * MODE — most queries are `WITH USER_MODE` (API 67). **THREE are `WITH SYSTEM_MODE`:**
 * `selectCallForOffersTargetsByIds`, `queryCallForOffersAlerts` and
 * `selectMarketSnapshotSourceByIds`. Read the METHOD, not the class.
 *
 * ⚠ THIS PARAGRAPH SAID "the ONE `WITH SYSTEM_MODE` method" UNTIL 2026-08-14 AND "TWO"
 * UNTIL 2026-08-16 — amended in place each time rather than left standing. The second
 * entrant is the alert job's locator, and its justification is argued at its own
 * declaration rather than borrowed from the first: it is SYSTEM_MODE because it selects
 * two custom fields created in that same change, which arrive with no FLS for any
 * profile including the deploying administrator. The third (the market-data freeze) is
 * argued at ITS own declaration for a THIRD reason again — it runs inside an
 * APPROVAL-TRIGGERED flow, so a throw does not merely disable the feature, it rolls back
 * the approval. Do not read a future fourth SYSTEM_MODE method as conformant because
 * three already exist — read its header.
 *
 * The thirteen USER_MODE methods back reads a human explicitly asked for. Opportunity
 * is the only standard-object selector in A1; per the P4 design §5 every standard
 * field selected there (Id, Name, StageName, CloseDate, CreatedDate) is
 * `permissionable=false` and therefore never subject to FLS — USER_MODE cannot
 * throw on it — and every custom field selected (Deal_Type__c, Asset_Type__c,
 * Asking_Price__c, Underwritten_NOI__c, Primary_*__c, and since 2026-08-14
 * Offer_Due_Date__c, Call_For_Offers_Received_Date__c, Broker_First_Seen__c,
 * Sale_Process__c, Listing_Broker_Name__c, Listing_Broker_Email__c,
 * Deal_Room_Link__c) is granted by the deployed Acquisition
 * permission sets — verified against DPEG_Acquisition_Edit / _View and
 * DPEG_Opportunity_View, per field, 2026-08-14. 🔴 NONE OF THEM MAY BE
 * WIDENED — the SYSTEM_MODE justification below is specific to an automation path
 * and does not transfer to a single one of them. **Adding a custom field to ANY
 * USER_MODE method here means re-verifying that grant list first**: USER_MODE throws
 * on the WHOLE ROW for ONE inaccessible field, so a new field can break a caller that
 * has nothing to do with it.
 *
 * SHARING — the class stays `with sharing`, and for the SYSTEM_MODE method that is a
 * SEPARATE decision from the mode, deliberately argued separately (see that method's
 * header). Conflating the two is the D25 mistake this repo has already paid for once.
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
     * days — backs the recency-scoped outcome cards
     * (Under Contract (PSA) / Closed Won / Dead-Pass).
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
     * The stages a deal is CLOSED at, for the "largest ACTIVE deals" read below.
     *
     * ⚠ `'Dead/Pass'` is the LITERAL runtime value and is what belongs in Apex and in a
     * ListView filter. The `Dead%2FPass` encoding applies inside BusinessProcess /
     * RecordType / picklist METADATA only — getting it backwards yields a filter that
     * silently never matches, so every dead deal stays in the list and nothing errors.
     *
     * 🔴 THE FILTER IS ON `StageName` AND MUST NEVER MOVE TO `Deal_Category__c`. Verified
     * repo-wide 2026-08-16: NOTHING in this application ever writes
     * `Deal_Category__c = 'Dead'` — its only writer is `flows/Transaction_Complete_Close`,
     * which writes `'Closed'`, and the field is a restricted picklist DEFAULTING to
     * `'Live'`. A `Deal_Category__c` filter therefore reads as a dead exclusion and is one.
     *
     * ⚠ `'About to Close'` is deliberately ABSENT. It is a live, working deal that has not
     * closed, and it is exactly the kind of deal this card exists to surface.
     */
    @TestVisible
    private static final Set<String> CLOSED_STAGES = new Set<String>{ 'Closed Won', 'Dead/Pass' };

    /**
     * Top Opportunities by `Amount` (largest first, amount-less deals last), EXCLUDING
     * closed deals — backs the "Top 5 Largest Deals" home-page card (FSD §24.2, "the five
     * biggest active deals, any stage except Closed").
     *
     * 🔴 IT RANKS ON `Amount`, NOT ON `Asking_Price__c`, AND THE TWO ARE DIFFERENT
     * QUESTIONS. `Asking_Price__c` is what the SELLER wants; `Amount` is what the DEAL is
     * worth to DPEG. `selectTopByAskingPrice` above answers the first and backs
     * `lwc/recentOpportunities`; this answers the second and backs `lwc/topLargestDeals`.
     * ⚠ They are DELIBERATELY two methods and two cards (user decision, 2026-08-16): an
     * earlier design proposed adding this stage filter to `selectTopByAskingPrice` and
     * relabelling the existing card. That was OVERRULED — the two lists answer different
     * questions and a deal can top one and not the other. Do not merge them, and do not
     * "harmonise" this method's ORDER BY onto `Asking_Price__c`; that silently turns this
     * card into a duplicate of the other one.
     *
     * ⚠ `TestDataFactory.createOpportunities` seeds `Amount` and `Asking_Price__c` to the
     * SAME value, so a test that does not deliberately diverge them cannot tell these two
     * methods apart and is VACUOUS. `OpportunitySelectorTest.selectTopByAmount_*` inverts
     * them on purpose.
     *
     * MODE — `WITH USER_MODE`, and that is the correct answer rather than the convenient
     * one: this backs a card a human opened a home page to read, so an FLS gap here is a
     * real provisioning gap and the fix is a permission set, not a mode change
     * (ARCHITECTURE.md §2). 🔴 BUT THE GRANT MUST BE VERIFIED BEFORE THIS SHIPS:
     * `Opportunity.Amount` is `permissionable`, and as at 2026-08-16 it is granted by NO
     * permission set in this repo (measured — it appears only in `profiles/**`, which is
     * `.forceignore`d and never deploys). USER_MODE throws on the WHOLE ROW for ONE
     * inaccessible field, so a persona without that grant gets `System.QueryException:
     * No such column 'Amount' on entity 'Opportunity'` — an FLS DENIAL wearing a schema
     * error — and the whole card renders its error banner. That failure is LOUD, which is
     * why it is the right posture here and the wrong one inside an approval-triggered
     * flow (see `selectMarketSnapshotSourceByIds`). Grant `Opportunity.Amount` readable on
     * `DPEG_Acquisition_Edit` / `DPEG_Acquisition_View` / `DPEG_Opportunity_View` — the
     * three sets that already carry `Opportunity.Deal_Bucket__c`.
     *
     * @param maxRows Row cap (LIMIT).
     * @return Opportunities not at a closed stage, ordered by Amount DESC NULLS LAST,
     *         CreatedDate DESC; empty when nothing matches. Never null.
     */
    public static List<Opportunity> selectTopByAmount(Integer maxRows) {
        return [
            SELECT Id, Name, StageName, Deal_Type__c, Asset_Type__c,
                   Amount, CloseDate, CreatedDate
            FROM Opportunity
            WHERE StageName NOT IN :CLOSED_STAGES
            WITH USER_MODE
            ORDER BY Amount DESC NULLS LAST, CreatedDate DESC
            LIMIT :maxRows
        ];
    }

    /**
     * The deal header plus its Property's ENTIRE live market-data block — the read behind
     * `MarketDataSnapshotService`'s freeze at underwriting approval (FSD §18.3 / §18.4).
     *
     * ═════════════════════════════════════════════════════════════════════════════
     * 🔴 MODE — `WITH SYSTEM_MODE`. A `USER_MODE` THROW HERE ROLLS BACK AN APPROVAL.
     * ═════════════════════════════════════════════════════════════════════════════
     * Every `Placer_*` / `CoStar_*` field in this SELECT is a Metadata-API-deployed custom
     * field, and such fields arrive with NO field permissions for ANY profile, System
     * Administrator INCLUDED. Under `USER_MODE` this read throws
     * `System.QueryException: No such column '<field>' on entity 'Property__c'` — an FLS
     * DENIAL wearing a schema error — and it does so inside an `@InvocableMethod` called
     * from `flows/Opportunity_UW_Approved_Notify`, an APPROVAL-TRIGGERED flow. So the
     * consequence is not "the snapshot is missing": it is the same shape as the
     * Disposition-NDA auto-create row in ARCHITECTURE.md §2's automation-path table — the
     * exception escapes and takes the principal's approval down with it.
     *
     * The read is also one the running user never ASKED for. A principal pressed Approve;
     * the platform is copying market data on their behalf. That is the definition of an
     * automation path.
     *
     * ═════════════════════════════════════════════════════════════════════════════
     * ⚠ SHARING IS A SEPARATE DECISION AND IS DELIBERATELY *NOT* ESCAPED
     * ═════════════════════════════════════════════════════════════════════════════
     * Conflating the two is the D25 mistake this repo has already paid for once, so it is
     * argued here rather than assumed. `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing.
     * No `without sharing` inner class is added, and the class stays `with sharing`,
     * because the argument is STRUCTURAL rather than optimistic:
     *
     *   - The ROOT object is `Opportunity` — the very deal the approver has just approved,
     *     so it is visible to them by construction. `Opportunity` OWD is also `ReadWrite`.
     *   - `Property__r.*` is a PARENT-LOOKUP TRAVERSAL, and traversal is not
     *     sharing-filtered; sharing filters the ROOT rows of a query.
     *
     * 🔴 READING `Property__c` AS A ROOT OBJECT WOULD BE A DEFECT, AND THAT IS WHY THIS
     * METHOD LIVES HERE RATHER THAN ON `PropertySelector`. `Property__c` is
     * `sharingModel = Private`; its single sharing rule is an OWNER rule scoped to rows
     * owned by the `Acquisition` QUEUE, and a `LeadConvertService`-created Property is
     * owned by the CONVERTER — so a principal approver is not reached. A root-level read
     * would return ZERO ROWS and the snapshot would be SILENTLY EMPTY while
     * `Market_Data_As_Of_Date__c` stamped: a record asserting "these are the numbers the
     * principals saw" and naming none. Nothing would throw and no test would fail.
     *
     * ⚠ NAMED FALLBACK, recorded rather than built: if traversal ever DOES prove to be
     * sharing-filtered, the remedy is a `private without sharing` inner class on
     * `PropertySelector` holding only that query — mirroring the existing
     * `FolderCreationReads` / `AssetCreationReads` — and NEVER `without sharing` on a
     * class backing a dozen user-facing reads.
     *
     * ⚠ FIELD SET — the composer names every field it reads, so ADDING a market field to
     * `Property__c` and forgetting it here means the snapshot silently under-reports while
     * still claiming completeness. Two `Property__c` LongTextArea fields
     * (`Comp_Sales__c`, `Visitor_Demographics__c`) are DELIBERATELY out of this list: they
     * are free-text narrative rather than metrics, they are unbounded, and either one
     * could consume the whole 32,768-character snapshot field by itself. That omission is
     * stated in the composed text so a reader is not misled into thinking they were blank.
     *
     * NOT-FOUND CONTRACT: read-for-use over a SET — returns the rows that exist. A missing
     * Id simply does not come back; the caller stamps a self-reporting body for it rather
     * than assuming success.
     *
     * @param opportunityIds Deals to snapshot; empty-safe.
     * @return The matching Opportunities with `Property__r` populated where the deal has a
     *         Property; empty when none match. Never null.
     */
    public static List<Opportunity> selectMarketSnapshotSourceByIds(Set<Id> opportunityIds) {
        return [
            SELECT Id, Name, Property__c,
                   Property__r.Name,
                   Property__r.Placer_State_Rank__c,
                   Property__r.Placer_State_Percentile__c,
                   Property__r.Placer_MSA_Rank__c,
                   Property__r.Placer_National_Rank__c,
                   Property__r.Monthly_Visits__c,
                   Property__r.Trade_Area_Population__c,
                   Property__r.Peak_Hour__c,
                   Property__r.YoY_Growth__c,
                   Property__r.Comp_Monthly_Visits__c,
                   Property__r.Placer_Data_Source__c,
                   Property__r.Placer_Last_Synced_DateTime__c,
                   Property__r.Placer_Fetch_Status__c,
                   Property__r.CoStar_Pct_Leased__c,
                   Property__r.CoStar_Location_Score__c,
                   Property__r.CoStar_Asking_Rent_PSF__c,
                   Property__r.CoStar_Exit_Cap_Rate__c,
                   Property__r.Market_Rent_PSF__c,
                   Property__r.Market_Cap_Rate__c,
                   Property__r.Occupancy_Rate_Market__c,
                   Property__r.Days_On_Market_Avg__c,
                   Property__r.CoStar_Data_Source__c,
                   Property__r.CoStar_Last_Synced_DateTime__c,
                   Property__r.CoStar_Fetch_Status__c
            FROM Opportunity
            WHERE Id IN :opportunityIds
            WITH SYSTEM_MODE
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
     * Count of Opportunities of a given deal type — backs the Land / Retail
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

    /**
     * Loads the fields ContractExecutionService needs when a Contract Review is
     * executed: the deal header (Name, Property) plus the primary-contract value
     * and primary-LOI earnest money it copies onto the new Transaction, and the
     * existing Contract_Executed_Date__c it only stamps when still blank.
     *
     * BULK read (Set<Id>): the caller processes a whole trigger chunk of executed
     * deals at once, so this returns a List — never a single row. The two
     * relationship fields (Primary_Contract__r.Contract_Value__c,
     * Primary_LOI__r.Earnest_Money__c) are null when the deal has no primary
     * contract/LOI, which the caller already null-guards; the row is still
     * returned.
     *
     * @param opportunityIds Executed-deal Opportunity Ids to load (bound with IN).
     * @return Opportunities with the handoff field set populated; an empty list
     *         when opportunityIds is null/empty.
     * @example
     * List<Opportunity> opps =
     *     OpportunitySelector.selectExecutionHandoffByIds(executedOppIds);
     */
    public static List<Opportunity> selectExecutionHandoffByIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id, Name, Property__c, Contract_Executed_Date__c,
                   Primary_Contract__r.Contract_Value__c, Primary_LOI__r.Earnest_Money__c
            FROM Opportunity
            WHERE Id IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * Loads a deal's brokerage-firm reference — the Account and its Name — for the
     * Opportunity record-page sidebar (backs BrokerFirmController.getBrokerFirm).
     * Added by P4 cleanup wave G.
     *
     * FETCH-FOR-USE: BrokerFirmController already null-checked opportunityId and
     * assigned the original query straight to a single Opportunity, then dereferenced
     * `opp.AccountId` WITHOUT a null-guard on the record itself — so a miss must throw,
     * not return null (returning null would NPE the caller). Preserved here via a
     * single-row SOQL assignment that throws native System.QueryException on a miss.
     *
     * @param opportunityId Opportunity Id to load; must reference an existing row.
     * @return The Opportunity with Id, AccountId, and Account.Name populated.
     * @throws System.QueryException when no Opportunity matches the Id.
     */
    public static Opportunity selectAccountRefById(Id opportunityId) {
        return [
            SELECT Id, AccountId, Account.Name
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Count of an Account's Opportunities grouped by stage — backs the firm-level
     * deal counts (submitted / won / lost) on the Opportunity sidebar
     * (BrokerFirmController.getBrokerFirm). Added by P4 cleanup wave G.
     *
     * @param accountId The brokerage-firm Account whose deals to aggregate.
     * @return AggregateResult rows with alias `st` (StageName) and `c` (COUNT(Id));
     *         empty when the Account has no Opportunities.
     * @example
     * for (AggregateResult ar : OpportunitySelector.countByStageForAccount(accountId)) { ... }
     */
    public static List<AggregateResult> countByStageForAccount(Id accountId) {
        return [
            SELECT StageName st, COUNT(Id) c
            FROM Opportunity
            WHERE AccountId = :accountId
            WITH USER_MODE
            GROUP BY StageName
        ];
    }

    /**
     * Opportunities in a set that have a Primary LOI designated — backs
     * ApprovalAuditService's LOI-gate stamp, which reads each deal's Primary_LOI__c
     * to know which LOI to mark Approved. Added by P4 cleanup wave G.
     *
     * BULK read (Set<Id>): the audit invocable processes a whole batch of LOI-gate
     * deals at once, so this returns a List — never a single row. The
     * `Primary_LOI__c != null` filter mirrors the original inline query so deals
     * without a primary LOI are excluded at the query, not in Apex.
     *
     * @param opportunityIds Deal Ids to load (bound with IN); null/empty-safe.
     * @return Opportunities (Id, Primary_LOI__c) that have a non-null Primary_LOI__c;
     *         an empty list when the input is null/empty or none qualify (never null).
     */
    public static List<Opportunity> selectPrimaryLoiByIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id, Primary_LOI__c
            FROM Opportunity
            WHERE Id IN :opportunityIds AND Primary_LOI__c != null
            WITH USER_MODE
        ];
    }

    /**
     * The current call-for-offers stamp values for a set of deals — backs
     * `CallForOffersStampService.stamp`, which reads them ONCE in bulk so it can skip
     * every record nothing would change on (which is what makes a platform redelivery
     * a genuine zero-DML no-op). Added 2026-08-10, Tranche 4B (decisions D26 / D8).
     *
     * ═══ 🔴 TWO KEYWORDS, TWO SEPARATE QUESTIONS. DO NOT COLLAPSE THEM. ═══
     * `WITH SYSTEM_MODE` lifts CRUD and FLS. It does NOT touch sharing — sharing is
     * governed by this class's `with sharing` keyword, in BOTH modes. Prescribing a mode
     * change as the fix for a sharing problem is exactly the error recorded as D25 in
     * `agent-output/stage-by-stage-decisions.md`, so each half is argued on its own below.
     *
     * ▸ MODE = SYSTEM_MODE, because this is an AUTOMATION-PATH read (ARCHITECTURE.md §2).
     *   The running principal never asked for it: it happens on their behalf while an
     *   inbound broker email is routed. `Broker_Protection_Access` — the permission set the
     *   pipeline principal actually holds — declares SIX `objectPermissions` blocks
     *   (`Competing_Broker_Submission__c`, `Inbound_Email_Staging__c`,
     *   `Property_Claim_Lock__c`, `Property_Registry__c`, `Task`, `UserExternalCredential`)
     *   and **no `Opportunity` entry of any kind**, nor any `Opportunity` field permission
     *   (verified against the file 2026-08-10). `WITH USER_MODE` does not degrade, it
     *   THROWS — `System.QueryException: No such column 'Offer_Due_Date__c' on entity
     *   'Opportunity'`, which is how the platform reports an FLS denial — and that throw
     *   would abort the whole call-for-offers branch. Every DPEG persona sits on
     *   `Minimum Access - Salesforce`, so this is the default case here, not an edge case.
     *
     * ▸ SHARING = `with sharing`, and it is SUFFICIENT rather than merely inherited.
     *   `Opportunity` OWD is **`ReadWrite`** — measured against the org via the Tooling API
     *   (`EntityDefinition`) on 2026-08-10, not read off this repo. Under a ReadWrite
     *   default every user already has read/write access to every Opportunity row, so a
     *   `with sharing` read returns the same rows a `without sharing` one would. There is
     *   nothing for a `private without sharing` inner class to fix, and adding one would
     *   widen a boundary for no measured reason.
     *
     * 🔴 RESIDUAL, AND IT IS THE FAILURE MODE THIS FEATURE FAILS BY. OWD is ORG state, not
     * repo state — `objects/Opportunity/Opportunity.object-meta.xml` says `ReadWrite`, but
     * standard-object OWD is UI-only and this repo has been measured contradicting the org
     * before. If Opportunity is ever narrowed to Private, this read silently returns ZERO
     * ROWS for a pipeline principal who owns no deals, and the `Database.update` is then never
     * attempted at all — so there is no `SaveResult`, no refusal, and nothing for
     * `allOrNone = false` to report. That is the 2026-08-08
     * `InboundEmailStagingSelector.RoutingReads` incident one module later.
     * ⚠ PARTIALLY MITIGATED 2026-08-10 (review finding S4), and only partially: this case now
     * lands in `CallForOffersStampService.StampResult.missing`, which the caller funnels into
     * `Inbound_Email_Staging__c.Error__c`, so the row reads `Status__c = 'Error'` naming each
     * unreadable deal instead of being indistinguishable from "no deal matched". The FEATURE is
     * still dead in that state; it merely stops being silent, and no test can prove the sharing
     * behaviour itself (post-deploy gate G5, run AS THE PIPELINE PRINCIPAL, is the only proof).
     * THE REMEDY, IF IT EVER HAPPENS, IS A NARROW `private without sharing` INNER
     * CLASS HOLDING ONLY THIS METHOD (the `LeadSelector.GuestReads` /
     * `InboundEmailStagingSelector.RoutingReads` shape) — never `without sharing` on this
     * whole class, which backs eleven user-facing reads.
     *
     * 🔴 AND THIS METHOD IS ONLY HALF THE CHAIN — THE OTHER HALF HAS NOT BEEN ANALYSED TO THE
     * SAME DEPTH, WHICH IS WHY IT IS NAMED HERE (review finding W2, 2026-08-10). Before the
     * branch can ask this method for anything it must first RESOLVE a deal Id, and it does that
     * through `PropertyMatchingService.resolveLiveRecord` -> `LeadSelector.selectConversionById`,
     * which is `WITH USER_MODE` on a `with sharing` class. `USER_MODE` THROWS on an FLS denial,
     * which is loud and recoverable; but if that read is ever FILTERED rather than refused —
     * sharing, not FLS — then `rows.isEmpty()` is true, `resolveLiveRecord` returns the LEAD Id
     * unchanged, `findLiveDealForProperty` sees a non-Opportunity and reports NO MATCH. The
     * email is then labelled `Not Routed (call for offers)` with no error, no refusal, no
     * `missing` entry and no failing test — the same silent shape as the residual above, one
     * read earlier. It is NOT broken today: branches (d) and (e) make the identical call on the
     * live production path. But "the chain has been analysed" must not be inferred from this
     * header alone.
     *
     * BULK read (Set<Id>): the caller resolves a whole email's matched deals at once, so
     * this returns a List and is called ONCE per email regardless of property count. Never
     * call it per property.
     *
     * ⚠ `Sale_Process__c` JOINED THE FIELD SET 2026-08-12 AND IS NOT OPTIONAL, and
     * `Call_For_Offers_Received_Date__c` JOINED IT 2026-08-14 ON THE SAME TERMS. Both are read
     * for the SAME reason as the original three: `CallForOffersStampService.buildChange` compares
     * the incoming value against the stored one so an already-current deal is dropped from the
     * update list entirely (zero DML — the idempotency guarantee). Selecting one fewer field
     * than the service writes would make every replay of the same campaign email churn
     * `LastModifiedDate` on a live deal. Whatever this method selects and whatever that method
     * writes must stay the same set.
     *
     * @param opportunityIds Matched deal Ids to load (bound with IN); null/empty-safe.
     * @return Opportunities with Id, Offer_Due_Date__c, Listing_Broker_Name__c,
     *         Listing_Broker_Email__c, Sale_Process__c and Call_For_Offers_Received_Date__c
     *         populated; an empty list when the input is null/empty (never null).
     * @example
     * List&lt;Opportunity&gt; targets =
     *     OpportunitySelector.selectCallForOffersTargetsByIds(matchedIds);
     */
    public static List<Opportunity> selectCallForOffersTargetsByIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id, Offer_Due_Date__c, Listing_Broker_Name__c, Listing_Broker_Email__c,
                   Sale_Process__c, Call_For_Offers_Received_Date__c
            FROM Opportunity
            WHERE Id IN :opportunityIds
            WITH SYSTEM_MODE
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CALL-FOR-OFFERS SURFACES + ALERT JOB (Phase 4, 2026-08-14)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * ⚠ THE TWO USER_MODE CALL-FOR-OFFERS READS BELOW REPEAT THEIR FIELD LIST VERBATIM, AND THAT IS
     * DELIBERATE. Hoisting it into a `String` constant would force `Database.query`, i.e. DYNAMIC
     * SOQL — which this repo does not use anywhere (`RecordStageAdvanceService`'s header states "no
     * dynamic SOQL anywhere" as a property of the design), which loses compile-time field
     * validation, and which would let a future field rename deploy green and fail at runtime. Ten
     * repeated field names is the cheaper cost. 🔴 WHATEVER ONE SELECTS, THE OTHER MUST SELECT:
     * `CallForOffersService.evaluateAll` reads all ten off both, so a field present in one and
     * absent from the other is a `SObjectException: SObject row was retrieved via SOQL without
     * querying the requested field` on exactly one of the two surfaces.
     *
     * 🔴 BOTH LISTS DELIBERATELY OMIT `Offer_Alert_Last_Interval__c` AND `Offer_Alert_Due_Date__c`, AND
     * THAT OMISSION IS THE POINT. Both are Metadata-API-deployed custom fields, which arrive with
     * NO field permissions for ANY profile, System Administrator included. `WITH USER_MODE` does not
     * degrade, it THROWS (`No such column ... on entity 'Opportunity'` — which is how the platform
     * reports an FLS denial), so adding either of them here would make the Lead Funnel table and the
     * record-page panel depend on the FLS of two fields that exist purely as alert bookkeeping and
     * that no human needs to see. The `InboundEmailStagingSelector.selectById` lesson exactly: the
     * change made to support a feature becomes that feature's newest single point of failure.
     * The batch reads them, in `SYSTEM_MODE`, in its own method below.
     *
     * ⚠ IT ALSO DELIBERATELY DOES NOT TRAVERSE `Property__r.Name`. `LeadConvertService` names the
     * deal after the property, so `Name` already IS the property name; traversing would add a
     * cross-object CRUD/FLS dependency, and `DPEG_Opportunity_View` — the Transactions team's
     * Opportunity subset — grants nothing at all on `Property__c`. Under USER_MODE that is not a
     * blank column, it is the whole read throwing for that persona.
     *
     * ⚠ EVERY CUSTOM FIELD BELOW IS GRANTED BY `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View` AND
     * `DPEG_Opportunity_View` (verified against the files 2026-08-14). Widening this list means
     * re-verifying all three, or the read throws for whichever persona is missing the new grant.
     *
     * ⚠ `Call_For_Offers_Received_Date__c` WAS ADDED TO BOTH LISTS 2026-08-14, AND THE RULE ABOVE
     * WAS FOLLOWED RATHER THAN ASSUMED: it is `<readable>true</readable>` in all three sets, and
     * additionally in `DPEG_Admin_Access` — which is the set the deploying administrator holds and
     * therefore the one the deploy's own `RunLocalTests` phase runs under. A brand-new
     * Metadata-API-deployed field arrives with NO field permissions for ANY profile, so without
     * that fourth grant this USER_MODE read would throw for the very administrator shipping it.
     * 🔴 IT IS THE ONE NEW FIELD THAT BELONGS HERE, AND THE TWO ALERT MARKERS STILL DO NOT — the
     * distinction is not "how new is it" but WHO THE READ IS FOR. This one is displayed to a human
     * in the Received column, so an FLS gap SHOULD surface; the markers are alert bookkeeping no
     * human reads, so making a user-facing table depend on their FLS would be the
     * `InboundEmailStagingSelector.selectById` mistake.
     */

    /**
     * Every OPEN deal carrying a call-for-offers due date, soonest deadline first — backs
     * `CallForOffersService.upcoming()` and, through it, the Lead Funnel table.
     *
     * MODE = `WITH USER_MODE`. This is a read a human explicitly asked for by opening a tab, so an
     * FLS gap SHOULD surface rather than be lifted; the automation-path exception does not apply.
     * See the block comment above for why the field list is exactly what it is.
     *
     * SHARING = `with sharing` (the class keyword), correct for a user-facing list: a user should
     * see the deals they can see. `Opportunity` internal OWD is `ReadWrite` (measured against the
     * org 2026-08-14 via `EntityDefinition`), so today that is every row.
     *
     * ⚠ CLOSED DEALS ARE EXCLUDED. A won or dead deal has no live offer deadline to chase, and
     * leaving them in would grow this table monotonically forever.
     *
     * 🔴 BUDGET: exactly ONE query regardless of how many deals match. It is deliberately NOT
     * `LIMIT`ed — the component decides how many rows to paint, and a selector that silently
     * truncated would make the table's own count wrong.
     *
     * @return Matching Opportunities, soonest deadline first, Id ascending as the tiebreak so the
     *         order is deterministic across runs; empty when nothing matches (never null).
     * @example
     * List&lt;Opportunity&gt; deals = OpportunitySelector.selectCallForOffersOpen();
     */
    public static List<Opportunity> selectCallForOffersOpen() {
        return [
            SELECT Id, Name, CreatedDate, Offer_Due_Date__c, Call_For_Offers_Received_Date__c,
                   Broker_First_Seen__c, Sale_Process__c, Listing_Broker_Name__c,
                   Listing_Broker_Email__c, Deal_Room_Link__c
            FROM Opportunity
            WHERE Offer_Due_Date__c != NULL
              AND IsClosed = FALSE
            WITH USER_MODE
            ORDER BY Offer_Due_Date__c ASC, Id ASC
        ];
    }

    /**
     * One deal's call-for-offers block — backs `CallForOffersService.forOpportunity` and the
     * Opportunity record-page panel.
     *
     * MODE / SHARING / field list: identical reasoning to `selectCallForOffersOpen` above.
     *
     * ⚠ IT DOES NOT FILTER ON `IsClosed`. The list surface excludes closed deals because a closed
     * deal is not something to chase; the RECORD PAGE is a different question — a user standing on
     * a closed deal is entitled to see what its deadline was. Do not "harmonise" the two.
     *
     * NOT-FOUND CONTRACT: fetch-for-use, but this one returns NULL rather than throwing, because
     * its caller renders a "no deadline" state for a miss (a record-page panel must not blow up on
     * a record the user cannot read). That is a deliberate divergence from
     * `selectPrimaryRefsById` / `selectStageRequiredById`, whose callers wanted the native throw.
     *
     * @param opportunityId The deal to load; null-safe.
     * @return The Opportunity with the call-for-offers fields populated, or null when the input is
     *         null or the Id resolves to no readable row.
     * @example
     * Opportunity deal = OpportunitySelector.selectCallForOffersById(recordId);
     */
    public static Opportunity selectCallForOffersById(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<Opportunity> rows = [
            SELECT Id, Name, CreatedDate, Offer_Due_Date__c, Call_For_Offers_Received_Date__c,
                   Broker_First_Seen__c, Sale_Process__c, Listing_Broker_Name__c,
                   Listing_Broker_Email__c, Deal_Room_Link__c
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The alert job's WORK QUEUE — every open deal whose call-for-offers deadline is close enough
     * to be inside the notification ladder. Backs `CallForOffersAlertBatch.start`.
     *
     * ═══ 🔴 TWO KEYWORDS, TWO SEPARATE QUESTIONS — the D25 rule, applied again ═══
     *
     * ▸ MODE = `WITH SYSTEM_MODE`, on AUTOMATION-PATH grounds (ARCHITECTURE.md §2), and here the
     *   argument is unusually concrete: this query selects `Offer_Alert_Last_Interval__c` and
     *   `Offer_Alert_Due_Date__c`, both created in this same change. A Metadata-API-deployed custom
     *   field arrives with NO field permissions for ANY profile, System Administrator included — so
     *   under `USER_MODE` this locator would throw for the very administrator who deployed it, on
     *   day one, and the alert feature would be silently dead while everything looked shipped. No
     *   principal ever asks for this read; the scheduler performs it on the team's behalf.
     *
     * ▸ SHARING = `with sharing` (the class keyword), and it is SUFFICIENT rather than merely
     *   inherited. `Opportunity` internal OWD is **`ReadWrite`** — measured against `usman-dpeg`
     *   2026-08-14 via `EntityDefinition` (`internal=ReadWrite external=Private`), not read off this
     *   repo — so every user already sees every Opportunity row and a `without sharing` inner class
     *   would widen a boundary for no measured reason.
     *
     *   🔴 RESIDUAL, STATED BECAUSE IT IS THIS JOB'S SILENT-FAILURE MODE. OWD is ORG state, not repo
     *   state, and standard-object OWD is UI-only so no file in this repo governs it. If Opportunity
     *   is ever narrowed to Private, this locator returns ZERO ROWS for a scheduling principal who
     *   owns no deals, `finish()` logs an all-zeros summary, and that is INDISTINGUISHABLE FROM A
     *   HEALTHY PIPELINE with nothing to alert on — the 2026-08-08
     *   `InboundEmailStagingSelector.RoutingReads` incident, one module later. The remedy then is a
     *   narrow `private without sharing` inner class holding ONLY this query (the
     *   `LeadSelector.GuestReads` shape), never `without sharing` on this class, which backs
     *   thirteen user-facing reads.
     *
     * ═══ THE CEILING IS A REAL FILTER; THERE IS DELIBERATELY NO FLOOR ═══
     * `Offer_Due_Date__c <= TODAY + 7` is exactly the widest rung of `CallForOffersService`'s
     * ladder, so a deal 30 days out is never even read. There is NO lower bound: a long-overdue deal
     * stays in this locator forever and is skipped in memory, because the marker makes it a no-op
     * (once interval 0 is stamped, the strictly-smaller test can never pass again). That costs one
     * row per pass and buys correctness for the case that actually matters — a deal created AFTER
     * its deadline passed, which has no marker and genuinely is owed its one alert. ⚠ Adding a floor
     * would silence that deal, so it is an ALERT-LOSS decision, not a tuning knob: if the overdue
     * population ever grows enough to matter, take it THEN with the population as evidence. Same
     * reasoning, and the same deliberate restraint, as `DealFolderSweepBatch`'s missing retry cap.
     *
     * ⚠ THE `+ 7` IS DUPLICATED KNOWLEDGE AND IS THE ONE PLACE IT IS ALLOWED. A `Database.QueryLocator`
     * cannot bind an Apex collection, so the ladder's widest rung cannot be read from
     * `CallForOffersService` here. It is a CEILING, not a threshold — widening it costs extra rows
     * that the in-memory ladder then skips, and narrowing it below the widest rung is the only way
     * to break the feature. Whoever adds a rung above 7 must widen this too.
     *
     * @return A locator over open deals with a deadline inside the ladder, soonest first.
     * @example
     * public Database.QueryLocator start(Database.BatchableContext ctx) {
     *     return OpportunitySelector.queryCallForOffersAlerts();
     * }
     */
    public static Database.QueryLocator queryCallForOffersAlerts() {
        Date ceiling = Date.today().addDays(7);
        return Database.getQueryLocator([
            SELECT Id, Name, Offer_Due_Date__c, Offer_Alert_Last_Interval__c,
                   Offer_Alert_Due_Date__c, Sale_Process__c, Listing_Broker_Name__c
            FROM Opportunity
            WHERE Offer_Due_Date__c != NULL
              AND Offer_Due_Date__c <= :ceiling
              AND IsClosed = FALSE
            WITH SYSTEM_MODE
            ORDER BY Offer_Due_Date__c ASC, Id ASC
        ]);
    }
}
