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
 *   - OpportunityApprovalService (the signed-NDA submission gate — selectNdaGateById,
 *     `WITH SYSTEM_MODE`, see MODE below)
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
 *     selectTopActiveByAskingPrice, `WITH USER_MODE`)
 *   - PortfolioDealController (the c/portfolioDealSiblings card on the Opportunity record
 *     page — selectPackageAnchorById, `WITH USER_MODE`; the OPPORTUNITY-rooted half of
 *     that feature's two reads, the portfolio-deal-rooted half being
 *     PortfolioDealSelector.selectWithMembersById)
 *   - BrokerCounterRecalcBatch (the nightly Contact broker-counter recalculation —
 *     aggregateDealCountsByBroker, `WITH SYSTEM_MODE`, see MODE below)
 *   - StageDelayAlertBatch (the daily stalled-deal reminder — queryStalledDeals,
 *     `WITH SYSTEM_MODE`, see MODE below)
 *   - DealTransactionGateService.recalculate (the "a deal cannot close until its
 *     transaction is closed" gate, from TransactionTrigger —
 *     selectTransactionGateFlagsByIds, `WITH SYSTEM_MODE`, see MODE below)
 *
 * MODE — most queries are `WITH USER_MODE` (API 67). **EIGHT are `WITH SYSTEM_MODE`:**
 * `selectCallForOffersTargetsByIds`, `queryCallForOffersAlerts`,
 * `selectMarketSnapshotSourceByIds`, `selectNdaGateById`,
 * `aggregateDealCountsByBroker`, `queryStalledDeals`, `selectPrimaryLoiByIds` and
 * `selectTransactionGateFlagsByIds`. Read the METHOD, not the class.
 *
 * ⚠ THIS PARAGRAPH SAID "the ONE `WITH SYSTEM_MODE` method" UNTIL 2026-08-14, "TWO"
 * UNTIL 2026-08-16, "THREE" UNTIL 2026-08-30, "FOUR" UNTIL 2026-08-31, "FIVE" FOR A
 * FEW HOURS OF THAT SAME DAY AND "SIX" UNTIL 2026-09-01 — amended in
 * place each time rather than
 * left standing. The second
 * entrant is the alert job's locator, and its justification is argued at its own
 * declaration rather than borrowed from the first: it is SYSTEM_MODE because it selects
 * two custom fields created in that same change, which arrive with no FLS for any
 * profile including the deploying administrator. The third (the market-data freeze) is
 * argued at ITS own declaration for a THIRD reason again — it runs inside an
 * APPROVAL-TRIGGERED flow, so a throw does not merely disable the feature, it rolls back
 * the approval. Do not read a future NINTH SYSTEM_MODE method as conformant because
 * eight already exist — read its header.
 *
 * 🔴 THE EIGHTH ENTRANT (`selectTransactionGateFlagsByIds`, 2026-09-02) IS THE SECOND
 * ENTRANT'S REASON — it selects two custom fields created in that same change, which arrive
 * with no FLS for any profile including the deploying administrator — WITH ONE AGGRAVATION
 * THE SECOND DID NOT HAVE: it runs on a TRIGGER path (`TransactionTrigger`), so a USER_MODE
 * throw does not disable a batch job quietly, it rolls back the saving user's own Transaction.
 * ⚠ Its SHARING answer is the OPPOSITE of `selectNdaGateById`'s and that is deliberate and
 * measured: Opportunity's INTERNAL OWD is `ReadWrite`, so no `without sharing` inner class is
 * added. Its sibling read in the same recompute,
 * `TransactionSelector.aggregateStatusCountsByOpportunityIds`, DOES escape sharing, because
 * `Transaction__c` is Private. Two reads, one feature, two different answers — which is the
 * D25 rule working, not an inconsistency.
 *
 * 🔴 THE SEVENTH ENTRANT (`selectPrimaryLoiByIds`, 2026-09-01) IS THE THIRD ENTRANT'S REASON
 * AGAIN — IT RUNS INSIDE AN APPROVAL-TRIGGERED FLOW — BUT IT IS THE ONLY ONE OF THE SEVEN
 * THAT WAS CONVERTED **AFTER** BEING MEASURED FAILING IN THAT EXACT WAY, SO ITS EVIDENCE IS
 * THE STRONGEST AND THE CHEAPEST TO RE-RUN. Test run `707iw000003unI3`, 2026-09-01,
 * `LoiApprovalStampServiceTest.nonOwningReadOnlyApproverStillUnblocksTheDeal`:
 *     System.DmlException: ... CANNOT_EXECUTE_FLOW_TRIGGER, ... the "LOI Approval Stamp"
 *     process failed ... System.QueryException: No such column 'Primary_LOI__c' on entity
 *     'Opportunity'.
 * 🔴 AND THE GRANT WAS **PRESENT**, WHICH IS THE PART WORTH CARRYING FORWARD. Measured in the
 * same session: `FieldPermissions` for `Opportunity.Primary_LOI__c` on `DPEG_Opportunity_View`
 * exists with `PermissionsRead = true`. What that permission set does NOT carry is any
 * `LOI__c` **objectPermissions** entry at all (its only `<object>` is `Opportunity`) — and a
 * lookup field is not accessible when its REFERENCED OBJECT is not, which this file already
 * states for the fourth entrant ("a cross-object traversal, so it needs read on `NDA__c` the
 * OBJECT too"). ⇒ **"Grant the FLS" is not an available fix here: the FLS is already granted.**
 * The failure direction is the same one the third entrant records and worse in one respect:
 * the throw escaped `ApprovalAuditService`'s degrade-by-design catch (the read sat OUTSIDE it,
 * fixed in the same change) and rolled back the parent stamp that unblocks the deal.
 *
 * 🔴 THE SIXTH ENTRANT (`queryStalledDeals`, 2026-08-31) IS THE **FIRST-CASE** ONE AGAIN —
 * a daily batch locator, performed by a scheduler on the team's behalf, never at a
 * principal's request — and the concrete trigger is the same one the SECOND entrant
 * records: it selects `Stage_Alert_Last_Sent_Date__c` and `Stage_Alert_Stage__c`, two
 * Metadata-API-deployed custom fields created in that same change, which arrive with NO
 * field permissions for ANY profile, System Administrator included. Under USER_MODE this
 * locator would throw `No such column` for the very administrator who deployed them, on
 * day one, and the reminder would be silently dead while everything looked shipped.
 *
 * 🔴 THE FIFTH ENTRANT (`aggregateDealCountsByBroker`, 2026-08-31) IS A **NIGHTLY BATCH**
 * READ AND ITS JUSTIFICATION IS THE FIRST-CASE ONE, NOT A NEW ONE: no principal asks for
 * it; `BrokerCounterRecalcBatch`'s scheduler performs it on the team's behalf, and it
 * aggregates `Broker__c` — a custom field — for a scheduling principal whose FLS nobody
 * controls. What is worth reading twice is the FAILURE DIRECTION, because it is worse here
 * than for the other four: this batch is a **reset writer** (it writes every Contact in
 * scope, including back to zero), so a read that returns nothing does not leave the
 * counters stale — it actively **overwrites correct counts with zeroes**. A USER_MODE
 * throw would at least be loud; a degraded read would be silent and destructive. That
 * asymmetry is also why the SHARING question was measured separately below rather than
 * assumed from the mode.
 *
 * 🔴 THE FOURTH ENTRANT (`selectNdaGateById`, 2026-08-30) IS THE ONE MOST LIKELY TO BE
 * MISREAD AS NON-CONFORMANT, BECAUSE IT SITS ON A UI PATH. It is reached from a quick
 * action a human clicked, which looks exactly like the "read a human asked for" case the
 * USER_MODE default governs. It is not: the human asked to SUBMIT FOR APPROVAL, and this
 * read is a CORRECTNESS GATE performed on their behalf before that submission — nothing
 * it returns is ever displayed. Its FOURTH, independent justification is argued at its
 * own declaration and turns on the direction of failure: under USER_MODE, one missing FLS
 * grant on `NDA__c.NDA_Signed__c` (a cross-object traversal, so it needs read on `NDA__c`
 * the OBJECT too) does not degrade the gate, it THROWS `No such column` — refusing a
 * legitimate submission with a schema error, for a permissions reason, on a persona the
 * gate was never about. ⚠ That is a FOURTH distinct reason, not a re-use of the first three.
 *
 * ⚠ THE COMPLEMENTARY COUNT WAS STALE UNTIL 2026-08-31 AND IS CORRECTED HERE, IN THE SAME
 * IN-PLACE STYLE THE SYSTEM_MODE COUNT ABOVE USES. This paragraph said "thirteen", and the
 * four other places in this file that partition the same 21 methods said "thirteen",
 * "fourteen", "eleven" and "thirteen" — none of them moved as entrants four, five and six
 * were added, because each of those edits amended only the SYSTEM_MODE side. The class's whole
 * discipline is that its counts are authoritative, so a half-amended partition is worse than
 * no count. RE-DERIVED BY ENUMERATION, not by arithmetic on the old figure: 21 public methods
 * = 6 `WITH SYSTEM_MODE` (the six named above) + 15 `WITH USER_MODE`.
 * ⚠ AMENDED 2026-09-01, BOTH SIDES, as this paragraph's own last line demands: no method was
 * added or removed, `selectPrimaryLoiByIds` MOVED from one side to the other, so it is now
 * 21 public methods = **7** `WITH SYSTEM_MODE` + **14** `WITH USER_MODE`.
 * ⚠ AMENDED AGAIN 2026-09-02, BOTH SIDES. `selectTransactionGateFlagsByIds` was ADDED (it did
 * not move), so the SYSTEM_MODE side gains one and the USER_MODE side does not:
 * **22 public methods = 8 `WITH SYSTEM_MODE` + 14 `WITH USER_MODE`.** RE-DERIVED BY
 * ENUMERATION on 2026-09-02 (`grep "^    public static"` returned 21 before this addition),
 * not by arithmetic on the previous figure.
 * 🔴 If you add a method, update BOTH sides or neither.
 *
 * The fourteen USER_MODE methods back reads a human explicitly asked for. Opportunity
 * is the only standard-object selector in A1; per the P4 design §5 the standard
 * fields selected across them (Id, Name, StageName, CloseDate, CreatedDate) are
 * `permissionable=false` and therefore never subject to FLS — USER_MODE cannot
 * throw on them — and every custom field selected (Deal_Type__c, Asset_Type__c,
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
 * 🔴 AND THAT RULE IS NOT CUSTOM-FIELD-ONLY. THE LESSON STANDS; ITS EXAMPLE HAS GONE.
 * The paragraph above enumerates the standard fields that are `permissionable=false`.
 * `Amount` is NOT among them and IS permissionable, so a standard field can throw here
 * exactly like a custom one. That was not theoretical: `Amount` was read as "standard
 * fields are always safe", a test was written asserting USER_MODE cannot throw for a
 * restricted persona, and it FAILED ON FIRST EXECUTION (2026-08-16, `RunLocalTests`).
 * ⇒ **Check `permissionable` on a STANDARD field before assuming it is FLS-free.**
 *
 * ⚠ SUPERSEDED, 2026-08-17: the example was `selectTopByAmount`, which selected `Amount`.
 * That method was re-ranked and RENAMED to `selectTopActiveByAskingPrice` (user decision),
 * and **no method on this class selects `Amount` any more** — so the counterexample is
 * historical rather than live. It is kept because it is the reason the `Opportunity.Amount`
 * grants exist on `DPEG_Acquisition_Edit` / `_View` / `DPEG_Opportunity_View`; do not read
 * this paragraph as evidence that some query here still depends on them. 🔴 NOR SHOULD
 * THOSE GRANTS BE REMOVED ON THE STRENGTH OF THIS NOTE — this class is not their only
 * possible consumer (layouts, list views and org-side reports name fields directly), and a
 * `PermissionSet` deploy REPLACES its whole `<fieldPermissions>` set, so dropping one is a
 * live-access change, not a tidy-up. That is an admin decision with its own evidence.
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
     * backs the "recent / biggest deals" list (`lwc/recentOpportunities`, via
     * `OpportunityFunnelController.getRecentOpportunities`).
     *
     * ⚠ IT HAS A NEAR-TWIN SINCE 2026-08-17 AND THE TWO MUST NOT BE MERGED.
     * `selectTopActiveByAskingPrice` below carries the IDENTICAL ORDER BY and differs in
     * exactly one axis: it excludes `CLOSED_STAGES`. 🔴 ADDING THAT FILTER HERE WOULD BREAK
     * THIS METHOD'S OWN CALLER — `recentOpportunities` shows deals at ANY stage — and it is
     * precisely the tranche-2 proposal the user OVERRULED on 2026-08-16. This method, its
     * controller method, its card, its label and its placement stay UNTOUCHED.
     * ⚠ It also selects `Underwritten_NOI__c`, which its card renders as an NOI column and
     * the other card does not have.
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
     * Top ACTIVE Opportunities by `Asking_Price__c` (highest first, price-less deals last),
     * EXCLUDING closed deals — backs the "Top 5 Largest Deals" home-page card
     * (FSD §24.2, "the five biggest active deals, any stage except Closed").
     *
     * ═════════════════════════════════════════════════════════════════════════
     * 🔴 THIS METHOD WAS `selectTopByAmount` AND RANKED ON `Amount` UNTIL 2026-08-17.
     * ═════════════════════════════════════════════════════════════════════════
     * The user re-ranked the card onto `Asking_Price__c` DELIBERATELY, with the
     * alternatives on the table: it now answers "the five highest ASKING PRICES among
     * active deals", not "the five biggest deal Amounts". Different deals appear.
     *
     * ⚠ RETRACTED, verbatim, because the next reader will otherwise restore it from the
     * argument rather than from the decision:
     *
     *     "🔴 IT RANKS ON `Amount`, NOT ON `Asking_Price__c`, AND THE TWO ARE DIFFERENT
     *      QUESTIONS ... do not 'harmonise' this method's ORDER BY onto `Asking_Price__c`;
     *      that silently turns this card into a duplicate of the other one."
     *
     * That prohibition is SPENT — the harmonisation it forbade is the change that was made,
     * on the user's instruction. The observation UNDER it is still true and still worth
     * knowing: `Asking_Price__c` is what the SELLER wants and `Amount` is what the DEAL is
     * worth to DPEG, so this card no longer reports the second of those at all.
     *
     * 🔴 IT WAS RENAMED RATHER THAN LEFT AS `selectTopByAmount`, AND THE ALTERNATIVE WAS
     * WEIGHED. A method named for the field it no longer orders by is a lying name — the
     * exact defect shape ARCHITECTURE.md §2 records for `LoiSelector`'s and `NdaSelector`'s
     * stale headers. A SIBLING method was the other option and was rejected: this method has
     * exactly ONE production caller (`TopDealsController.getTopDeals`, verified repo-wide
     * 2026-08-17), so a sibling would leave `selectTopByAmount` with ZERO callers — dead
     * code carrying a live-looking Javadoc. A rename touches one call site plus this class's
     * own tests.
     *
     * ═════════════════════════════════════════════════════════════════════════
     * 🔴 IT IS A SECOND METHOD, NOT A REUSE OF `selectTopByAskingPrice` ABOVE — AND THAT IS
     * NOW THE ONLY THING SEPARATING THE TWO HOME-PAGE CARDS. READ THIS BEFORE MERGING THEM.
     * ═════════════════════════════════════════════════════════════════════════
     * Both methods now ORDER BY `Asking_Price__c DESC NULLS LAST, CreatedDate DESC`. They
     * differ in one axis and it is load-bearing:
     *
     *   selectTopByAskingPrice        NO stage filter — closed deals included. Selects
     *                                 `Underwritten_NOI__c` (its card shows an NOI column).
     *                                 Backs `lwc/recentOpportunities`.
     *   selectTopActiveByAskingPrice  EXCLUDES `CLOSED_STAGES`, which is the whole of FSD
     *                                 §24.2's "any stage except Closed". Backs
     *                                 `lwc/topLargestDeals`.
     *
     * ⚠ Folding this into `selectTopByAskingPrice` by adding the stage filter there is
     * PRECISELY the tranche-2 proposal the user OVERRULED on 2026-08-16, and it would break
     * that method's own caller: `OpportunityFunnelController.getRecentOpportunities` shows
     * deals at ANY stage. So the reuse is not available, and the duplication that remains is
     * an ORDER BY clause rather than a query.
     *
     * ⚠ `TestDataFactory.createOpportunities` seeds `Amount` and `Asking_Price__c` to the
     * SAME value. That still matters, in the opposite direction from before: a test using
     * the factory defaults cannot prove this method ranks on `Asking_Price__c` rather than
     * on `Amount`, because both orderings agree. `OpportunitySelectorTest` and
     * `TopDealsControllerTest` diverge the two fields on purpose.
     *
     * MODE — `WITH USER_MODE`, and that is the correct answer rather than the convenient
     * one: this backs a card a human opened a home page to read, so an FLS gap here is a
     * real provisioning gap and the fix is a permission set, not a mode change
     * (ARCHITECTURE.md §2). USER_MODE throws on the WHOLE ROW for ONE inaccessible field,
     * so a persona without the grant gets `System.QueryException: No such column
     * 'Asking_Price__c' on entity 'Opportunity'` — an FLS DENIAL wearing a schema error —
     * and the whole card renders its error banner. That failure is LOUD, which is why it is
     * the right posture here and the wrong one inside an approval-triggered flow (see
     * `selectMarketSnapshotSourceByIds`).
     *
     * ✅ THE FLS SURFACE SHRANK WITH THIS CHANGE, and that is worth stating because it is
     * the one unambiguous improvement in it. The SELECT dropped `Amount` (permissionable
     * standard), `Deal_Type__c` and `Asset_Type__c` (Metadata-API-deployed customs, which
     * arrive with no field permissions for ANY profile) along with the columns that read
     * them, and `CloseDate` with the Close Date column. The only remaining FLS-bearing field
     * is `Asking_Price__c` — already granted on `DPEG_Acquisition_Edit` /
     * `DPEG_Acquisition_View` / `DPEG_Opportunity_View`, and already proven in production by
     * `selectTopByAskingPrice`, which the `recentOpportunities` card has run on for months.
     * `Id` / `Name` / `StageName` / `CreatedDate` are `permissionable=false`.
     *
     * ⚠ `StageName` IS SELECTED THOUGH NO COLUMN RENDERS IT. SOQL does not require a field
     * to be selected to filter on it, but `OpportunitySelectorTest` asserts row-by-row that
     * no returned deal sits at a closed stage — an assertion that reads `o.StageName` and
     * would throw `SObjectException` without it. It costs nothing (`permissionable=false`)
     * and it is what makes the exclusion falsifiable rather than trusted.
     *
     * ⚠ HISTORICAL, KEPT BECAUSE IT IS THE REASON THE `Opportunity.Amount` GRANTS EXIST:
     * this method's `Amount` version shipped on 2026-08-16 having found that field granted
     * by NO permission set in this repo (it appeared only in `profiles/**`, which is
     * `.forceignore`d and never deploys); the remedy — readable on `DPEG_Acquisition_Edit` /
     * `DPEG_Acquisition_View` / `DPEG_Opportunity_View` — was applied verbatim and verified
     * IN SOURCE on 2026-08-17. 🔴 THIS METHOD NO LONGER SELECTS `Amount`, so it is no longer
     * that grant's consumer. Do NOT infer that the grants may now be dropped: the class
     * header explains why that is an admin decision needing its own evidence.
     *
     * ⚠ STILL TRUE, AND THE PART A READER MUST NOT SKIP: a persona holding none of those
     * three sets is still denied `Asking_Price__c`, by design. That is not a defect —
     * `TopDealsController` converts it into a user-safe message, pinned by
     * `TopDealsControllerTest.anUnprovisionedPersonaGetsTheUserSafeMessageNotARawQueryException`.
     *
     * @param maxRows Row cap (LIMIT).
     * @return Opportunities not at a closed stage, ordered by Asking_Price__c DESC NULLS
     *         LAST, CreatedDate DESC; empty when nothing matches. Never null.
     */
    public static List<Opportunity> selectTopActiveByAskingPrice(Integer maxRows) {
        return [
            SELECT Id, Name, StageName, Asking_Price__c, CreatedDate
            FROM Opportunity
            WHERE StageName NOT IN :CLOSED_STAGES
            WITH USER_MODE
            ORDER BY Asking_Price__c DESC NULLS LAST, CreatedDate DESC
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
     * The `Portfolio_Deal__c` one deal belongs to — the ANCHOR read behind the
     * `c/portfolioDealSiblings` card on the Opportunity record page.
     *
     * 🔴 IT LIVES HERE, NOT IN `PortfolioDealSelector`, BECAUSE THIS IS A QUERY AGAINST
     * OPPORTUNITY. .claude/rules/apex-layering-rule.md is explicit that all SOQL for an
     * object lives in that object's selector and "nothing else queries it".
     * `PortfolioDealSelector.selectWithMembersById` owns the PORTFOLIO-DEAL-rooted read (which
     * returns both member collections via relationship subqueries, so the feature costs two
     * queries in total rather than three). `LeadSelector.selectPackageAnchorById` is this
     * method's exact twin — change both or neither.
     *
     * ⚠ THE METHOD NAME STILL SAYS "Package" AFTER THE 2026-08-18 PORTFOLIO DEAL RENAME
     * (phase B4), AND THAT WAS A DECISION RATHER THAN AN OVERSIGHT. B4 was scoped to repoint
     * this class's REFERENCES — the query below reads `Opportunity.Portfolio_Deal__c` — and
     * deliberately left its public surface alone, because permission-set headers cite this
     * method BY NAME as the standing justification for an FLS grant and those files belong to
     * a parallel task. Read the query, not the name. Renaming is a clean follow-up that must
     * move all four sites at once: here, `LeadSelector`,
     * `PortfolioDealController.resolvePortfolioDealId`, and the permission-set headers.
     *
     * 🔴 THE OLD `Opportunity.Property_Package__c` STILL EXISTS AND IS STILL POPULATED until
     * phase B5 retires it. Nothing in this class reads it any more.
     *
     * USER_MODE, per the §2 default and the class header above: this backs a card on a
     * record page the human already opened, at their request. It is NOT one of this class's
     * three automation-path SYSTEM_MODE methods and must not become a fourth — the
     * arguments for those three (a trigger that would roll back a stage change, a batch
     * locator reading a field with no FLS for any profile, an approval-triggered flow) do
     * not apply to a user-requested page read. `Opportunity.Portfolio_Deal__c` is granted
     * in DPEG_Acquisition_Edit and DPEG_Acquisition_View, declared in-file.
     *
     * NOT-FOUND CONTRACT — an empty list, never null and never a throw, DELIBERATELY unlike
     * the `selectStageRequiredById` / `selectPrimaryRefsById` fetch-for-use family
     * immediately around it. Those two are dereferenced straight away by callers for whom a
     * miss is a defect; this one backs a card whose job is to render nothing when there is
     * nothing to render.
     *
     * ═══ ⚠ THE PORTFOLIO DEAL'S `Name` IS DELIBERATELY NOT SELECTED HERE (2026-08-17, review W2) ═══
     * The spanning `Portfolio_Deal__r.Name` was in this SELECT and was REMOVED. The only consumer
     * — `PortfolioDealController.resolvePortfolioDealId` — reads `Portfolio_Deal__c` and nothing else;
     * the card's heading comes from `PortfolioDealSelector.selectWithMembersById`, which selects
     * `Name` off the portfolio deal itself one query later. A parent traversal under `WITH USER_MODE` needs
     * READ on the parent OBJECT as well as FLS on the field, so carrying it here was an extra,
     * unused way for this anchor read to THROW. `LeadSelector.selectPackageAnchorById` was changed
     * identically — change both or neither.
     *
     * @param opportunityId The Opportunity whose portfolio deal to resolve; null returns an empty list
     *                      WITHOUT querying.
     * @return At most one Opportunity (Id, Portfolio_Deal__c — the Id only, never the
     *         portfolio deal's Name); empty when the Id is null or matches no row.
     * @throws System.QueryException when the running user lacks FLS on
     *         `Opportunity.Portfolio_Deal__c`.
     * @example
     * List<Opportunity> rows = OpportunitySelector.selectPackageAnchorById(recordId);
     */
    public static List<Opportunity> selectPackageAnchorById(Id opportunityId) {
        if (opportunityId == null) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id, Portfolio_Deal__c
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
     * The two stored deal-close gate flags as they currently STAND — backs
     * `DealTransactionGateService.recalculate`, which compares them with a freshly-counted truth
     * and writes back only the deals whose flags actually moved (added 2026-09-02).
     *
     * ── WHY A READ EXISTS AT ALL, WHEN THE SERVICE COULD JUST WRITE ───────────────────────────
     * The query buys a skipped DML, and the DML is the expensive half. An Opportunity update
     * re-enters `OpportunityReviewTrigger`, and this read runs on `Transaction__c`'s trigger path,
     * which the Day-0 chain walks several times per deal. Reading first is what lets a Transaction
     * save whose flags did not move cost zero writes.
     *
     * ── 🔴 MODE = `WITH SYSTEM_MODE`. THIS IS THE CLASS'S EIGHTH, AND ITS REASON IS THE SECOND
     * ENTRANT'S, NOT A NEW ONE ────────────────────────────────────────────────────────────────
     * `Has_Open_Transaction__c` and `Has_Closed_Transaction__c` are custom fields created in this
     * same change, and a Metadata-API-deployed field arrives with NO FLS for ANY profile,
     * System Administrator included — the same fact that converted `queryStalledDeals`. Worse
     * here, because the caller is a TRIGGER: `USER_MODE` throws
     * `System.QueryException: No such column` rather than degrading, and inside an after-trigger
     * that escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the Transaction save
     * of whoever happened to be closing a transaction. It also runs as the Transactions team, who
     * are not required to hold any Opportunity FLS at all.
     *
     * ── 🟢 SHARING = NOT ESCAPED, AND THAT IS A MEASUREMENT RATHER THAN AN OMISSION ────────────
     * `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing, so it is asked separately, as the D25
     * rule at `selectNdaGateById` requires. Measured on `usman-dpeg` 2026-09-02 via
     * `EntityDefinition`: **Opportunity's INTERNAL sharing model is `ReadWrite`** (the external
     * model is `Private`). Every internal principal can therefore already read and write every
     * deal, there is nothing for a `private without sharing` inner class to fix, and adding one
     * would widen the class for no gain. This is the OPPOSITE answer from
     * `TransactionSelector.aggregateStatusCountsByOpportunityIds`, its sibling in the same
     * recompute, which DOES escape — because `Transaction__c` is Private and Opportunity is not.
     * 🔴 IF OPPORTUNITY'S INTERNAL OWD IS EVER TIGHTENED, RE-OPEN THIS. A sharing-filtered read
     * here would silently stop returning deals the saver cannot see, and
     * `DealTransactionGateService` would then write those deals BLIND rather than skip them — safe,
     * but it would quietly cost a DML per save. The remedy then is a narrow
     * `private without sharing` inner class holding ONLY this query (the `NdaGateReads` shape
     * above), never `without sharing` on this class.
     *
     * @param opportunityIds Deals to read; may be null/empty.
     * @return The deals with Id and both gate flags populated; an empty list when the input is
     *         null/empty. Deals the running user cannot see are simply ABSENT — the caller must
     *         treat absence as "unknown", never as "unchanged".
     * @example
     * for (Opportunity stored
     *         : OpportunitySelector.selectTransactionGateFlagsByIds(dealIds)) { ... }
     */
    public static List<Opportunity> selectTransactionGateFlagsByIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id, Has_Open_Transaction__c, Has_Closed_Transaction__c
            FROM Opportunity
            WHERE Id IN :opportunityIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * The signed-NDA submission gate's inputs: a deal's stage plus its primary NDA and whether
     * that NDA is signed. Backs `OpportunityApprovalService.submitForApproval`, which refuses an
     * LOI-stage submission when the primary NDA is blank or unsigned.
     *
     * ═══ 🔴 TWO KEYWORDS, TWO SEPARATE QUESTIONS — the D25 rule ═══
     *
     * ▸ MODE = `WITH SYSTEM_MODE`, and this is the class's FOURTH such method (the header's count
     *   and list were amended in place, per its own instruction). It is the one that looks least
     *   like an automation read, so the argument is made in full rather than borrowed:
     *
     *   - THE READ IS NOT THE THING THE HUMAN ASKED FOR. They asked to submit for approval. This
     *     query is a correctness gate run on their behalf before that submission, and NOTHING it
     *     returns is ever rendered. The USER_MODE default in ARCHITECTURE.md §2 governs "a read
     *     the running user ASKED FOR", where a throw reports a real provisioning gap and the fix
     *     is a permission set. Here a throw would report nothing to anybody: it would refuse a
     *     legitimate submission.
     *   - `USER_MODE` THROWS, IT DOES NOT DEGRADE, AND THE SURFACE IS UNUSUALLY WIDE. This is a
     *     CROSS-OBJECT traversal (`Primary_NDA__r.NDA_Signed__c`), so under USER_MODE it needs
     *     read on the `NDA__c` OBJECT as well as FLS on that field — for every persona who can
     *     click Submit for Approval. `DPEG_Opportunity_View`, the Transactions team's Opportunity
     *     subset, is precisely the shape of persona that has the Opportunity and not the child.
     *     One missing grant anywhere in that set turns the gate into `System.QueryException: No
     *     such column` — an FLS denial wearing a schema error — which the controller then masks
     *     as "The deal could not be submitted for approval." Nobody could diagnose that.
     *   - THE FAILURE DIRECTION IS THE DECIDING ARGUMENT. SYSTEM_MODE can only make the gate
     *     EVALUATE; it cannot make it pass. A deal with an unsigned NDA is still refused, and
     *     refused with the actionable message. USER_MODE would trade a correct refusal for an
     *     incorrect one.
     *
     * ▸ SHARING = 🔴 **`without sharing`, VIA THE NARROW `NdaGateReads` INNER CLASS BELOW** — a
     *   SEPARATE decision from the mode, and one that was settled BY MEASUREMENT on 2026-08-30
     *   rather than by argument.
     *
     *   ⚠ THIS BULLET USED TO READ, AND THE CODE USED TO MATCH: *"SHARING = `with sharing` (the
     *   class keyword) … It is sufficient here and deliberately so: the caller is submitting THIS
     *   record for approval from its own record page, so they demonstrably already have it.
     *   `Opportunity` internal OWD is `ReadWrite` … so today every user sees every row anyway."*
     *   🔴 THAT REASONING WAS CORRECT AND COMPLETE ABOUT THE **ROOT** ROW, AND ENTIRELY SILENT
     *   ABOUT THE **TRAVERSED PARENT** — which is where the whole risk lived. `Opportunity` OWD is
     *   irrelevant to `Primary_NDA__r`; **`NDA__c` OWD is `Private`**.
     *
     *   ═══ THE MEASUREMENT (2026-08-30, org `usman-dpeg`, test run `707iw000003bQwp`) ═══
     *   `OpportunityApprovalServiceTest.aSubmitterWhoCannotSeeTheNdaIsNotFalselyBlocked` and
     *   `theOwnedRecordControlStillSubmits` were written against a `DPEG_Opportunity_View` persona
     *   on the `Minimum Access - Salesforce` profile — Opportunity read + viewAllRecords, and NO
     *   `NDA__c` object permission of any kind — with `UserRecordAccess.HasReadAccess = false` on
     *   the NDA asserted as a precondition. **BOTH FAILED** against the `with sharing` version:
     *   a submitter who could not READ the NDA was REFUSED a deal whose NDA WAS SIGNED.
     *   ⇒ A `WITH SYSTEM_MODE` spanning read IS sharing-filtered on the parent. `SYSTEM_MODE` lifts
     *   CRUD/FLS and, as ARCHITECTURE.md §2 says, **NEVER sharing** — the parent simply comes back
     *   NULL, indistinguishable from "no NDA linked".
     *
     *   🔴 THAT IS WHY THIS ONE NEEDED THE ESCAPE AND MOST READS DO NOT: the failure does not
     *   DEGRADE, IT INVERTS. A sharing-filtered read here does not hide information from someone
     *   who should not see it — it fabricates "this deal has no signed NDA" and BLOCKS a
     *   legitimate submission, for every non-owner, on exactly the deals that have reached LOI.
     *   Strictly worse than the failure the gate exists to prevent.
     *
     *   ⚠ THE ESCAPE IS AS NARROW AS THE PLATFORM ALLOWS: a `private without sharing` inner class
     *   holding ONLY this one query (the `InboundEmailStagingSelector.RoutingReads` /
     *   `ProcessInstanceStepSelector.AuditReads` shape ARCHITECTURE.md §2 prescribes).
     *   🔴 DO NOT PUT `without sharing` ON THIS CLASS. It backs twenty other reads, fifteen of
     *   them user-facing `USER_MODE` reads whose whole job is to respect what the user may see.
     *
     *   ⚠ IT WIDENS NOTHING A USER CAN OBSERVE. The only thing that escapes the inner class is a
     *   `Boolean` consumed by a guard; no NDA field is returned to the caller, rendered, or
     *   logged. The submitter learns only whether their own submission is allowed — which they
     *   were always entitled to know.
     *
     *   ⚠ IF THE ROW ITSELF IS INVISIBLE this still returns null and the gate is SKIPPED — see the
     *   NOT-FOUND CONTRACT below for why skipping is right and not a hole.
     *
     * NOT-FOUND CONTRACT — returns NULL for a null Id or a row that resolves to nothing, and
     * DELIBERATELY does not throw, unlike the `selectStageRequiredById` fetch-for-use family two
     * methods above. That is load-bearing rather than stylistic: the "unexpected failure
     * propagates RAW from `Approval.process`" contract in `OpportunityApprovalService` is
     * PRE-EXISTING, and a gate that threw `QueryException` first would move where that failure
     * originates and silently change which exception a caller sees. A null row means "cannot
     * evaluate the gate", the gate is skipped, and `Approval.process` fails exactly as it did
     * before this method existed.
     *
     * @param opportunityId The deal whose NDA state to read; null-safe.
     * @return The Opportunity with Id, StageName, Primary_NDA__c and Primary_NDA__r.NDA_Signed__c
     *         populated, or null when the input is null or the Id resolves to no row.
     * @example
     * Opportunity deal = OpportunitySelector.selectNdaGateById(targetId);
     */
    public static Opportunity selectNdaGateById(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        return new NdaGateReads().ndaGateById(opportunityId);
    }

    /**
     * 🔴 THE SHARING ESCAPE FOR THE SIGNED-NDA GATE, AND NOTHING ELSE.
     *
     * `without sharing` is confined to this inner class so it applies to ONE query. The enclosing
     * `OpportunitySelector` stays `with sharing` and must: it backs twenty other reads, fifteen of
     * them user-facing `USER_MODE` reads whose entire job is to respect what the running user may
     * see. This is the `InboundEmailStagingSelector.RoutingReads` /
     * `ProcessInstanceStepSelector.AuditReads` shape ARCHITECTURE.md §2 prescribes.
     *
     * The full justification — including the 2026-08-30 measurement that established it was
     * necessary, and why the failure it prevents INVERTS rather than degrades — is at
     * `selectNdaGateById`'s own declaration. Read it before touching this.
     *
     * ⚠ DO NOT ADD A SECOND METHOD HERE. Every query that lands in this class silently inherits an
     * escape argued for a different one. A new read that needs the same treatment needs its OWN
     * inner class and its OWN measurement — that is the point of keeping these narrow.
     */
    private without sharing class NdaGateReads {

        /**
         * The gate's four fields, read without sharing so the `Primary_NDA__r` traversal is not
         * filtered by the submitter's access to the Private-OWD `NDA__c` parent.
         *
         * @param opportunityId The deal to read; never null (the wrapper guards it).
         * @return The row, or null when no row matches.
         */
        private Opportunity ndaGateById(Id opportunityId) {
            List<Opportunity> rows = [
                SELECT Id, StageName, Primary_NDA__c, Primary_NDA__r.NDA_Signed__c
                FROM Opportunity
                WHERE Id = :opportunityId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        }
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
     * ═══ 🔴 IT NOW ALSO CARRIES THE THREE FIRM-LEVEL ROLL-UPS (2026-08-30, Item 6.1) ═══
     * `Account.Total_Deals_Submitted__c`, `Account.Deals_Won__c` and `Account.Deals_Lost__c` are
     * native roll-up summaries over the firm's Opportunities. Carrying them on THIS row is what
     * lets `BrokerFirmController` stop running a second `GROUP BY` aggregate
     * (`countByStageForAccount`) for the same three numbers: the sidebar card went from TWO
     * queries to ONE, and — the actual point — the card and the `Broker_Leaderboard` report now
     * read the SAME stored numbers instead of two independent derivations that can silently
     * disagree.
     *
     * ⚠ THEY ARE SPANNED, NOT FETCHED BY A SECOND `AccountSelector` READ, and that is consistent
     * rather than a layering shortcut: this method ALREADY spans `Account.Name` for the same card,
     * and the query is still a query against `Opportunity`, which this class owns.
     *
     * 🔴 FLS — THIS IS A `WITH USER_MODE` READ AND THE THREE FIELDS ARE NEW, SO THEY MUST BE
     * GRANTED BEFORE THIS DEPLOYS OR THE WHOLE SIDEBAR CARD THROWS. USER_MODE throws on the WHOLE
     * ROW for one inaccessible field, so a missing grant does not blank three numbers — it turns
     * `getBrokerFirm` into "The brokerage firm summary could not be loaded" for every persona that
     * lacks it, including the deploying administrator (a Metadata-API-deployed field arrives with
     * no FLS for anyone). Required: `<readable>true</readable>` in every set whose persona opens
     * an Opportunity record page — at minimum `DPEG_Account_View`, `DPEG_Acquisition_Edit`,
     * `DPEG_Acquisition_View`, `DPEG_Opportunity_View` and `DPEG_Admin_Access`.
     * ⚠ `<editable>true</editable>` on a ROLL-UP SUMMARY FAILS THE DEPLOY. Readable only, always.
     *
     * ⚠ MODE STAYS `USER_MODE` AND MUST NOT BECOME THE CLASS'S FIFTH `SYSTEM_MODE` METHOD. This
     * is a card on a record page a human opened, at their request — the textbook USER_MODE case in
     * ARCHITECTURE.md §2, where a throw reports a real provisioning gap and the fix is a permission
     * set. The FLS burden above is the REASON to grant the fields, not a reason to lift the check.
     *
     * @param opportunityId Opportunity Id to load; must reference an existing row.
     * @return The Opportunity with Id, AccountId, Account.Name and the three Account roll-ups
     *         populated.
     * @throws System.QueryException when no Opportunity matches the Id, or when the running user
     *         lacks read on `Account` or on any of the three roll-up fields.
     */
    public static Opportunity selectAccountRefById(Id opportunityId) {
        return [
            SELECT Id, AccountId, Account.Name,
                   Account.Total_Deals_Submitted__c, Account.Deals_Won__c, Account.Deals_Lost__c
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Count of an Account's Opportunities grouped by stage.
     *
     * ═══ ⚠ ITS ORIGINAL CALLER WAS REPOINTED ON 2026-08-30. THE METHOD IS KEPT DELIBERATELY. ═══
     * RETRACTED, verbatim: "backs the firm-level deal counts (submitted / won / lost) on the
     * Opportunity sidebar (BrokerFirmController.getBrokerFirm)". IT NO LONGER DOES.
     * `BrokerFirmController` now reads the three native Account roll-up summaries spanned by
     * `selectAccountRefById`, so the card and the `Broker_Leaderboard` report cannot drift — one
     * stored source, not two live derivations (design Item 6.1 / RESIDUAL-8, user decision
     * 2026-08-30 which reversed the earlier "out of scope" call, Q10).
     *
     * 🔴 IT IS NOT DEAD CODE TO BE SWEPT. Two class headers cite this aggregate BY NAME as the
     * documented shape of a behaviour — `LeadConvertMatchService` ("Several Leads can converge on
     * ONE Account … this aggregates EVERY Opportunity on an Account") and
     * `LeadConvertMatchServiceTest` — and deleting it would falsify both while removing the
     * per-stage breakdown the roll-ups deliberately do not provide (they are three fixed counts;
     * this returns every stage). It also remains the honest answer for any future caller that
     * needs a stage breakdown rather than the three headline numbers. Its own test
     * (`OpportunitySelectorTest.countByStageForAccount_scopesToAccountAndGroupsByStage`) stays.
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
     * ═══ 🔴 TWO KEYWORDS, TWO SEPARATE QUESTIONS — the D25 rule ═══
     *
     * ▸ MODE = `WITH SYSTEM_MODE`. ⚠ CHANGED 2026-09-01 (W4 of the LOI approval cutover). It was
     *   `WITH USER_MODE`, and that was **measured wrong**, not argued wrong — see the class
     *   header's "SEVENTH ENTRANT" block for the exact test run and error text. In short:
     *     - THE READ IS NOT THE THING ANY HUMAN ASKED FOR. It happens inside
     *       `flows/LOI_Approval_Stamp`, an after-save flow fired by an APPROVER'S DECISION, and
     *       nothing it returns is ever rendered. That is ARCHITECTURE.md §2's automation path.
     *     - `USER_MODE` THROWS, IT DOES NOT DEGRADE, AND THE THROW LANDED ON THE APPROVAL SAVE.
     *       `System.QueryException: No such column 'Primary_LOI__c' on entity 'Opportunity'` —
     *       an FLS denial wearing a schema error — surfaced to the approver as
     *       `CANNOT_EXECUTE_FLOW_TRIGGER` and rolled back the parent stamp
     *       (`LoiApprovalStampService`) that unblocks the deal out of `Under Contract (PSA)`.
     *     - 🔴 AND THE OBVIOUS REMEDY DOES NOT EXIST. `DPEG_Opportunity_View` **already grants**
     *       `Opportunity.Primary_LOI__c` read (`FieldPermissions.PermissionsRead = true`,
     *       measured 2026-09-01). It carries no `LOI__c` objectPermissions, and a LOOKUP field is
     *       inaccessible when its REFERENCED OBJECT is — the same dependency `selectNdaGateById`
     *       records for `NDA__c`. So this cannot be fixed by adding an FLS line; it would need
     *       whole-object `LOI__c` read granted to every persona that can ever be an approver,
     *       which is a widening nobody asked for to serve a read nobody asked for.
     *
     * ▸ SHARING = `with sharing` (the class keyword), DELIBERATELY, and this is not an oversight
     *   carried over from the USER_MODE version. Ask the direction-of-failure question this repo
     *   settled on 2026-08-30: a sharing-filtered read here DEGRADES (a deal the running user
     *   cannot see is simply not stamped with the approver's name), it does not INVERT — there is
     *   no guard downstream that reads "no row" as a refusal. Contrast `selectNdaGateById`, whose
     *   null parent fabricates "this deal has no signed NDA" and blocks a legitimate submission;
     *   that one needed `NdaGateReads` and this one does not. Two further facts keep the residual
     *   small: the approving principals hold `viewAllRecords` on Opportunity via
     *   `DPEG_Acquisition_View`, and this is a ROOT-object read with no traversal, so there is no
     *   parent to come back null. 🔴 If a future caller ever turns a missing row here into a
     *   refusal, re-open this — the remedy would be a narrow `private without sharing` inner class
     *   holding ONLY this query (the `NdaGateReads` shape), never `without sharing` on this class.
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
            WITH SYSTEM_MODE
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
     * whole class, which backs fifteen user-facing `USER_MODE` reads.
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
     *
     * ⚠ `Offer_Status__c` WAS ADDED TO BOTH LISTS 2026-08-30, AND IT PASSES THE SAME TEST FOR THE
     * SAME REASON: it is DISPLAYED — as a row on the record-page panel and as a column in the Lead
     * Funnel table — so a persona who cannot read it should see the read fail rather than see a
     * blank they would take for "no status". It is therefore a USER_MODE field, and the rule above
     * applies in full: 🔴 IT NEEDS `<readable>true</readable>` IN FOUR SETS BEFORE THIS DEPLOYS —
     * `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Opportunity_View` AND
     * `DPEG_Admin_Access`. The fourth is not belt-and-braces: a Metadata-API-deployed field arrives
     * with NO field permissions for ANY profile, System Administrator included, and
     * `DPEG_Admin_Access` is the set the deploying administrator holds — i.e. the one the deploy's
     * own `RunLocalTests` phase runs under. Without it this read throws for the very person
     * shipping it, and BOTH call-for-offers surfaces go down at once. Exactly the gap
     * `Call_For_Offers_Received_Date__c` documented above.
     *
     * ⚠ AND IT IS THE FIELD THE ALERT LOCATOR *FILTERS* ON WITHOUT SELECTING. That asymmetry is
     * deliberate and is argued at `queryCallForOffersAlerts`: a suppressed deal never reaches the
     * batch's chunk, so the batch makes no decision from the value. Do not "harmonise" the three
     * field lists — two of them are user-facing reads and the third is an automation locator.
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
                   Listing_Broker_Email__c, Deal_Room_Link__c, Offer_Status__c
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
                   Listing_Broker_Email__c, Deal_Room_Link__c, Offer_Status__c
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
     *   fifteen user-facing `USER_MODE` reads.
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
     * ═══ 🔴 THE `Offer_Status__c` SUPPRESSION, AND THE SOQL NULL TRAP IN IT (2026-08-30) ═══
     * Once offers are in, or the campaign is closed, there is nothing left to chase, so a deal at
     * `Submitted` or `Closed` is excluded from the work queue entirely. The filter lives HERE
     * rather than in the batch because it is a POPULATION filter, not a ladder threshold — the
     * ladder is `CallForOffersService`'s and stays there — and because excluding a row before
     * chunking is strictly cheaper than reading it and skipping it.
     *
     * 🔴 THE PREDICATE IS WRITTEN AS A TWO-LEGGED OR AND MUST STAY THAT WAY:
     *     (Offer_Status__c = NULL OR Offer_Status__c NOT IN ('Submitted','Closed'))
     * The "obvious" single-legged form — `Offer_Status__c NOT IN ('Submitted','Closed')` — is
     * WRONG AND SILENTLY CATASTROPHIC. SOQL evaluates a `NOT IN` against NULL as UNKNOWN, and an
     * UNKNOWN row is EXCLUDED. `Offer_Status__c` is new in this change and a picklist `<default>`
     * does NOT backfill, so on day one EVERY existing deal carries null — the single-legged form
     * would return ZERO ROWS, the job would log a healthy all-zeros summary, and the entire
     * call-for-offers alert feature would be dead with nothing anywhere reporting it.
     * `OpportunitySelectorTest.queryCallForOffersAlerts_stillIncludesNullStatus` is the falsifier
     * and is the more valuable of the two tests added with this filter.
     *
     * ⚠ THE FIELD IS FILTERED ON BUT DELIBERATELY NOT SELECTED. The batch makes no decision from
     * it — a suppressed deal never reaches the chunk — so selecting it would imply to the next
     * reader that the ladder consults it. Same reasoning, and the same shape, as
     * `queryCallForOffersAlerts_doesNotSelectTheReceivedDate` immediately below it in the tests.
     *
     * @return A locator over open, non-suppressed deals with a deadline inside the ladder,
     *         soonest first.
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
              AND (Offer_Status__c = NULL
                   OR Offer_Status__c NOT IN ('Submitted', 'Closed'))
            WITH SYSTEM_MODE
            ORDER BY Offer_Due_Date__c ASC, Id ASC
        ]);
    }

    /**
     * Every deal count a broker Contact needs, in ONE aggregate: total submissions, wins and
     * losses, grouped by broker AND by stage. Backs `BrokerCounterRecalcBatch` (design §2 ITEM
     * 6.2/6.4), which turns these rows into `Contact.Deals_Submitted__c` / `Deals_Won__c` /
     * `Deals_Lost__c`.
     *
     * ═══ ✅ THE JOIN IS EXACT. THERE IS NO EMAIL MATCHING HERE, FUZZY OR OTHERWISE ═══
     * `BrokerLeaderboardService`'s class header carries a prominent warning that any broker
     * rollup would need *"Apex plus a fuzzy email match … under which a broker with two
     * addresses becomes ONE SILENTLY UNDERCOUNTED Contact."* 🔴 **THAT WARNING DOES NOT APPLY
     * TO THIS METHOD AND MUST NOT BE RE-INHERITED HERE.** It was written about
     * `Competing_Broker_Submission__c`, whose broker identity is a **Text email with no Contact
     * lookup at all** — so a Contact rollup off THAT object really would need a match step.
     * `Opportunity.Broker__c` is a **real Contact lookup**, stamped by `LeadConvertService`
     * (`o.Broker__c = l.ConvertedContactId`). `GROUP BY Broker__c` is therefore an Id join, and
     * a broker with two email addresses is one Contact Id here by construction. This query does
     * not touch `Competing_Broker_Submission__c`.
     *
     * ═══ ONE QUERY, TWO GROUPING KEYS — AND THE 2,000-ROW CLIFF THAT SIZES THE BATCH ═══
     * Grouping by `Broker__c, StageName` answers all three counts from a single aggregate, so
     * the caller's per-chunk budget stays constant in the number of DEALS. The cost is that the
     * row count is `|brokers in chunk| × |distinct stages they occupy|`, and an aggregate
     * assigned to a `List<AggregateResult>` throws above **2,000 rows**.
     * 🔴 `Opportunity.StageName` has **10 values** (`OpportunityStage.standardValueSet`,
     * counted 2026-08-31), so a 200-row chunk could produce 2,000 rows — EXACTLY the cliff.
     * That is why `BrokerCounterRecalcBatch.SCOPE` is **100 and not the inherited 200**; the
     * arithmetic and the instruction to redo it live in that class's header §1. **Adding an
     * Opportunity stage narrows that headroom — go read it.**
     *
     * ⚠ WINS AND LOSSES ARE NOT FILTERED IN THE QUERY, DELIBERATELY. The predicate is
     * `Broker__c IN :ids` and nothing else, so a broker with deals at no terminal stage still
     * returns rows and the caller can tell "0 wins" from "not in this result at all". Adding
     * `AND StageName IN ('Closed Won','Dead/Pass')` would make the total count unavailable and
     * cost a second query to get it back.
     *
     * ═══ 🔴 TWO KEYWORDS, TWO SEPARATE QUESTIONS — the D25 rule, applied again ═══
     *
     * ▸ MODE = `WITH SYSTEM_MODE`, on AUTOMATION-PATH grounds (ARCHITECTURE.md §2), argued at
     *   this declaration and not borrowed from the four SYSTEM_MODE methods above it. It
     *   aggregates `Broker__c`, a Metadata-API-deployed custom field, for a nightly scheduling
     *   principal. Under `USER_MODE` one missing grant does not degrade the count, it THROWS
     *   `No such column` inside `execute()`, the chunk is swallowed by the batch's fail-soft
     *   catch, and the job logs an all-zeros pass. See the class header's fifth-entrant note for
     *   why the failure direction is worse for a reset writer than for the other four.
     *
     * ▸ SHARING = `with sharing` (the class keyword), and it is SUFFICIENT — **measured, not
     *   inherited**. `Opportunity` `InternalSharingModel` was re-queried via the Tooling API
     *   (`SELECT InternalSharingModel FROM EntityDefinition WHERE DeveloperName = 'Opportunity'`)
     *   against `usman-dpeg` on **2026-08-31** and returned **`ReadWrite`** (external `Private`).
     *   Every internal principal already sees every deal, so this aggregate CANNOT under-count a
     *   broker for a sharing reason and a `without sharing` inner class would widen a boundary
     *   for no measured cause.
     *   ⚠ The Item 6 task brief asserted "Opportunity OWD is Private". **That is wrong** — it was
     *   checked before this method was written, precisely because an under-count here would be
     *   invisible. Recorded so the claim is not re-adopted from memory.
     *
     *   🔴 RESIDUAL, AND IT IS SHARPER FOR THIS CALLER THAN FOR `queryCallForOffersAlerts`. OWD is
     *   ORG state, not repo state, and standard-object OWD is UI-only so no file here governs it.
     *   If Opportunity is ever narrowed to Private, this aggregate returns FEWER rows for a
     *   scheduling principal who owns no deals — and because the caller is a reset writer, that
     *   does not merely skip an alert, it **writes zeroes over every correct count in the org,
     *   nightly, with nothing reporting it**. The remedy then is a narrow `private without
     *   sharing` inner class holding ONLY this query (the `NdaGateReads` shape above), never
     *   `without sharing` on this class.
     *
     * ⚠ TESTED FROM `BrokerCounterRecalcBatchTest`, NOT FROM `OpportunitySelectorTest`. That is a
     *   deliberate, temporary concession to hub-file contention: this method landed while a
     *   second developer stream was editing `OpportunitySelectorTest` for design ITEM 4. The
     *   tests are named `selector_aggregateDealCountsByBroker_*` so they are findable, and moving
     *   them here once ITEM 4 lands is a safe follow-up.
     *
     * @param brokerContactIds Broker Contact Ids to aggregate over (bound with IN); null/empty-safe.
     * @return AggregateResult rows with aliases `brokerId` (Broker__c), `st` (StageName) and `c`
     *         (COUNT(Id)); an empty list when the input is null/empty or no deal names any of
     *         them (never null). A broker with no deals is ABSENT — it is not returned as a zero.
     * @example
     * for (AggregateResult ar : OpportunitySelector.aggregateDealCountsByBroker(chunkIds)) {
     *     Id brokerId = (Id) ar.get('brokerId');
     *     String stage = (String) ar.get('st');
     * }
     */
    public static List<AggregateResult> aggregateDealCountsByBroker(Set<Id> brokerContactIds) {
        if (brokerContactIds == null || brokerContactIds.isEmpty()) {
            return new List<AggregateResult>();
        }
        return [
            SELECT Broker__c brokerId, StageName st, COUNT(Id) c
            FROM Opportunity
            WHERE Broker__c IN :brokerContactIds
            WITH SYSTEM_MODE
            GROUP BY Broker__c, StageName
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STALLED-DEAL REMINDER (design §2 ITEM 4, 2026-08-31)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * The stalled-deal reminder's WORK QUEUE — every OPEN deal that has been sitting in its stage
     * long enough to be worth reading. Backs `StageDelayAlertBatch.start`.
     *
     * ═══ 🔴 TWO KEYWORDS, TWO SEPARATE QUESTIONS — the D25 rule, applied again ═══
     *
     * ▸ MODE = `WITH SYSTEM_MODE`, on AUTOMATION-PATH grounds (ARCHITECTURE.md §2), argued HERE
     *   rather than borrowed from the five methods above it. The concrete trigger is the same one
     *   `queryCallForOffersAlerts` records: this query selects `Stage_Alert_Last_Sent_Date__c` and
     *   `Stage_Alert_Stage__c`, both created in this same change. A Metadata-API-deployed custom
     *   field arrives with NO field permissions for ANY profile, System Administrator included — so
     *   under `USER_MODE` this locator would throw `No such column` (which is how the platform
     *   reports an FLS denial) for the very administrator who deployed it, on day one, and the
     *   reminder would be silently dead while everything looked shipped. No principal ever asks for
     *   this read; the scheduler performs it on the team's behalf.
     *
     * ▸ SHARING = `with sharing` (the class keyword), and it is SUFFICIENT rather than merely
     *   inherited. 🔴 THE QUESTION WAS ASKED EXPLICITLY AND MEASURED, NOT ASSUMED, BECAUSE THE
     *   BRIEF THAT COMMISSIONED THIS METHOD ASSERTED THE OPPOSITE ("Opportunity OWD is Private").
     *   It is not. `Opportunity` internal OWD is **`ReadWrite`** — read off `usman-dpeg` on
     *   2026-08-31 via the Tooling API (`EntityDefinition.InternalSharingModel = ReadWrite`,
     *   `ExternalSharingModel = Private`), which is the same measurement
     *   `queryCallForOffersAlerts` recorded on 2026-08-14 and it has not moved. Every internal user
     *   already sees every Opportunity row, so a sharing-filtered read cannot skip deals owned by
     *   someone else and a `without sharing` inner class would widen a boundary for no measured
     *   reason.
     *
     *   🔴 RESIDUAL, STATED BECAUSE IT IS THIS JOB'S SILENT-FAILURE MODE AND IT IS SHARED WITH THE
     *   CALL-FOR-OFFERS JOB. OWD is ORG state, not repo state, and standard-object OWD is UI-only
     *   so no file in this repo governs it. If `Opportunity` is ever narrowed to Private, this
     *   locator returns ZERO ROWS for a scheduling principal who owns no deals, `finish()` logs an
     *   all-zeros summary, and that is INDISTINGUISHABLE FROM A HEALTHY PIPELINE with nothing to
     *   chase — the 2026-08-08 `InboundEmailStagingSelector.RoutingReads` incident, one module
     *   later. The remedy THEN is a narrow `private without sharing` inner class holding ONLY this
     *   query (the `LeadSelector.GuestReads` / `NdaSelector.ExpiryAlertReads` shape), never
     *   `without sharing` on this class, which backs fifteen user-facing `USER_MODE` reads.
     *
     * ═══ 🔴 THE CEILING IS A PARAMETER, AND THAT IS THE POINT ═══
     * `queryCallForOffersAlerts` above has to apologise for a hardcoded `TODAY + 7` because a
     * `Database.QueryLocator` cannot bind an Apex collection, so it could not read its ladder. That
     * constraint does NOT apply to a single `Date`. `StageDelayService.locatorCeiling(asOf)`
     * computes this argument from `Stage_Threshold_Def__mdt`, so **every threshold lives in exactly
     * one place and this selector holds no number at all.** Do not "simplify" it back into a
     * literal here.
     *
     * ⚠ IT IS A CHEAPNESS BOUND, NOT A CORRECTNESS BOUND. The caller passes the SMALLEST active
     * threshold — the widest net — and the per-stage decision is made in memory by
     * `StageDelayService.evaluate`. A deal read here whose stage has a larger threshold is simply
     * skipped. Widening the ceiling costs rows; narrowing it below the smallest active threshold is
     * the only way to break the feature.
     *
     * ═══ THE TWO FILTERS THAT ARE NOT OPTIONAL ═══
     * ▸ `IsClosed = FALSE` is the correct expression of "excluding Dead/Pass and Closed Won", and it
     *   is deliberately NOT a two-value `StageName NOT IN ('Dead/Pass','Closed Won')`. Both stages
     *   carry `IsClosed = true` (verified against `OpportunityStage` in `usman-dpeg` on 2026-08-31),
     *   the standard flag survives a future closed stage being added, and — decisively — a
     *   `NOT IN` against a picklist is the shape that produced the `Offer_Status__c` NULL trap
     *   documented on `queryCallForOffersAlerts`. `IsClosed` is a Boolean and cannot be null.
     * ▸ `Stage_Entry_Date__c != NULL` is LOAD-BEARING, not defensive. Every deal that existed before
     *   Item 2 shipped carries a null entry date until `scripts/backfill-opp-stage-entry-date.apex`
     *   is run (post-deploy step P4). Without this leg those rows would be read with no anchor;
     *   `StageDelayService.evaluate` classifies them `NO_ENTRY_DATE` and skips them anyway, so this
     *   is the cheaper half of one guard held in two places on purpose.
     *
     * ⚠ THERE IS DELIBERATELY NO LOWER BOUND. A deal that has been stuck for two years stays in this
     * locator forever and is skipped in memory, because the marker makes it a no-op after its one
     * reminder. That costs one row per pass and buys correctness for the deal that has never been
     * reminded. Same reasoning, same deliberate restraint, as `queryCallForOffersAlerts`.
     *
     * ⚠ `Days_In_Stage__c` — the deployed formula field — IS DELIBERATELY NOT SELECTED, even though
     * it holds the same number. A formula is evaluated per row at QUERY time; `StageDelayService`
     * evaluates the whole chunk against ONE `asOf` precisely so two deals in one run cannot straddle
     * midnight. Selecting it would invite a future reader to branch on it and reintroduce that.
     * The formula's job is the `Delayed_Opportunities` report and the dashboard.
     *
     * @param ceiling The latest `Stage_Entry_Date__c` a deal can carry and still possibly be
     *                delayed — `StageDelayService.locatorCeiling(Date.today())`. Never null; the
     *                service always returns a date (it falls back to the shipped threshold).
     * @return A locator over open, anchored deals at or past the widest threshold, longest-stalled
     *         first.
     * @example
     * public Database.QueryLocator start(Database.BatchableContext ctx) {
     *     return OpportunitySelector.queryStalledDeals(StageDelayService.locatorCeiling(Date.today()));
     * }
     */
    public static Database.QueryLocator queryStalledDeals(Date ceiling) {
        return Database.getQueryLocator([
            SELECT Id, Name, StageName, OwnerId, Stage_Entry_Date__c,
                   Stage_Alert_Last_Sent_Date__c, Stage_Alert_Stage__c
            FROM Opportunity
            WHERE IsClosed = FALSE
              AND Stage_Entry_Date__c != NULL
              AND Stage_Entry_Date__c <= :ceiling
            WITH SYSTEM_MODE
            ORDER BY Stage_Entry_Date__c ASC, Id ASC
        ]);
    }
}
