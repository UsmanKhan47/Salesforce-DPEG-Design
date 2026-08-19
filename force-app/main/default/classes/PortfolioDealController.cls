/**
 * Read-only `@AuraEnabled` controller for `Portfolio_Deal__c` — the ONE `@AuraEnabled` surface for
 * this object, backing TWO components:
 *
 *   • `getSiblingRecords(Id)`        → the record-page card that answers, on a Lead or an
 *     Opportunity record page, *"what ELSE arrived on the broker email this record came from?"*
 *   • `getRecentPortfolioDeals()`    → the Lead Funnel homepage widget answering
 *     *"which multi-property emails arrived most recently?"* (added 2026-08-17, design §8).
 *
 * ═══ 🔴 VOCABULARY — "PORTFOLIO DEAL" IS ALWAYS SPELLED IN FULL, NEVER SHORTENED TO "DEAL" ═══
 * Renamed from `PropertyPackageController` / `Property_Package__c` in phase B4 of the Portfolio
 * Deal rename (2026-08-18). The bare word "deal" means an **Opportunity** everywhere else in this
 * repo — and this class dispatches ON Opportunity, holds an `OPPORTUNITY_LABEL`, and returns
 * Opportunity sibling rows — so `getRecentDeals` / `RecentDealRow` / `dealId` were all rejected as
 * names here. They would read as "recent Opportunities" on a homepage that also shows recent Leads.
 * The verbosity is the point; do not "tidy" it back.
 *
 * ═══ 🔴 WHY THE SECOND METHOD IS HERE AND NOT ON `LeadFunnelController` ═══
 * It sits on the same homepage as `recentLeads`, which is the whole reason the question comes up. It
 * belongs here anyway: `LeadFunnelController`'s `FunnelData` / `LeadRow` DTOs are Lead-shaped end to
 * end, so a `Portfolio_Deal__c`-shaped return grafted onto them would mix two objects' concerns in
 * one controller for no reason beyond page adjacency. This class is already the read boundary for
 * this object (as `PortfolioDealSelector` is for its SOQL), and per the P6 read-only-controller
 * precedent a second thin `cacheable=true` method on an existing pure-read controller is a smaller,
 * more honest change than a new file.
 *
 * ⚠ SUPERSEDED 2026-08-17 (same day). This paragraph described `recentLeads`' grouping column in the
 * PRESENT tense — *"IT IS NOT A DUPLICATE"*, *"That column reads through
 * `LeadFunnelController.getFunnel()`"*, *"The two surfaces answer different questions and both
 * are wanted."* THERE IS NO SUCH COLUMN ANY MORE: it was removed once this method shipped, because the
 * two were redundant and this one is strictly better. `getRecentPortfolioDeals()` is now the ONLY
 * homepage surface for this object, not the second of two.
 *
 * THE REASONING IS UNCHANGED — it is what justified this method AND then retired the column, so read
 * it as a live constraint rather than as history. That column read through
 * `LeadFunnelController.getFunnel()`, which priority-partitions `LeadSelector.selectRecent(50)` and
 * then shows the first 5 rows; a portfolio deal's member Leads carry no priority of their own, so
 * unrelated high-priority Leads can occupy the visible rows and push a portfolio deal past the cutoff
 * entirely (observed with a direct server call — not a permission, FLS or deploy defect). This method
 * reads `Portfolio_Deal__c` DIRECTLY, with its own sort and its own cutoff, which is the only way to
 * sidestep an inherited partition rather than patch it.
 *
 * ⚠ SO "DO NOT SIMPLIFY BY MERGING IT BACK" NOW MEANS SOMETHING STRONGER, NOT SOMETHING OBSOLETE:
 * restoring the column would re-parent the read on the very partition this method exists to escape,
 * AND it is no longer a client-only edit — it would mean re-adding the two grouping fields to
 * `LeadFunnelController.LeadRow` and `Portfolio_Deal__c` + the spanning `Portfolio_Deal__r.Name`
 * to `LeadSelector.selectRecent`, whose `WITH USER_MODE` SELECT is the whole Lead Funnel homepage's
 * single point of FLS failure. `LeadFunnelControllerTest.getFunnel_leadRowCarriesNoPackageMembers` is
 * the falsifier (its NAME still says "Package" — phase B4 repointed the consumer classes' references
 * without renaming their own members; the assertion is about this object).
 *
 * ⚠ The per-record question *"what grouping is THIS record in?"* is still answered — by
 * `getSiblingRecords` above, on the Lead and Opportunity record pages, which the column's removal did
 * not touch. That is a different question from *"what arrived?"*, and the retired column was
 * a third, weaker answer to the first one.
 *
 * ═══ LAYER — thin controller, NO service class, DELIBERATELY ═══
 * It holds no SOQL and no business logic: it marshals, delegates to selectors, maps rows to a DTO
 * and maps any failure to a user-safe `AuraHandledException` at the LWC boundary
 * (ARCHITECTURE.md §5). No service layer is introduced, per the P6 read-only-controller precedent
 * — `LeadFunnelController`, `CompetingSubmissionController`, `SellMeterController` and
 * `RentRollController` are all pure reads with nothing to extract, and inventing a
 * `PortfolioDealReadService` that only forwards two calls would add a file, not a boundary.
 * ⚠ `PortfolioDealService` is NOT that class — it is the pipeline's WRITER and this controller must
 * never call it. `cacheable=true` because this is a pure read.
 *
 * ═══ 🔴 OBJECT-AGNOSTIC BY SERVER DISPATCH — THE WHOLE POINT OF THIS CLASS ═══
 * The method takes a bare `recordId` and switches on `recordId.getSObjectType()`. THE CLIENT NEVER
 * LEARNS AN OBJECT NAME, which is what lets ONE LWC bundle sit on BOTH record pages.
 *
 * ⚠ THAT PROPERTY IS WHY PHASE B4 COST THE CLIENT SO LITTLE. Renaming the object touched the two
 * anchor selectors and this file; the component learned nothing new, because it never knew the
 * object's name to begin with. The client's only coupling to this rename is the import path and
 * this class's own method and DTO names.
 *
 * This is deliberately the same shape as `RecordStageAdvanceController.hasStageActionAccess(Id)`,
 * and ARCHITECTURE.md §5 records what that shape has already bought: `Transaction__c` was added as
 * a SEVENTH object to that feature on 2026-08-12 with **zero changes to any client file**, and a
 * byte-identical second bundle created "so the module owns its own component" was DELETED the same
 * day (code review W3, user decision) — *"a copy carrying only a different header is not a split;
 * it is a second file that must now receive every fix this one gets."*
 *
 * ⚠ THE ALTERNATIVE THE BRIEF ORIGINALLY SUGGESTED WAS MEASURED AGAINST THIS AND REJECTED (design
 * §3). Reading the lookup client-side with `@wire getRecord` needs either
 * `@salesforce/schema/Lead.Portfolio_Deal__c` — which breaks object-agnosticism outright, since
 * Opportunity then needs a second import and a branch to choose between them — or a dynamic
 * `${objectApiName}.Portfolio_Deal__c`, which works but still needs a SECOND round trip for the
 * siblings plus an intermediate "grouping known, siblings not yet loaded" state in the component.
 * One Apex call taking only the Id has neither problem.
 *
 * ⚠ THE DISPATCH IS AN ALLOW-LIST, NOT A CHAIN OF GUESSES. An Id of any other type returns an
 * EMPTY result rather than throwing: the component is placed by an admin in App Builder, so a
 * placement on a third object is a configuration mistake that should render nothing, not a red
 * error banner on a deal page. Adding a third object here is a `when` branch plus that object's
 * own anchor selector method — never a new bundle.
 *
 * ═══ TWO QUERIES, NOT THREE, AND NEVER PER-ROW ═══
 * 1. the ANCHOR read — this record's `Portfolio_Deal__c` (`LeadSelector` /
 *    `OpportunitySelector`, because SOQL follows the object it queries);
 * 2. the PORTFOLIO-DEAL read — the row plus BOTH member collections, in one query, through
 *    relationship subqueries (`PortfolioDealSelector.selectWithMembersById`).
 * A null or unmatched Id short-circuits after query 1. Nothing here loops over a query.
 *
 * ═══ EMPTY IS AN ANSWER, NOT AN ERROR ═══
 * The overwhelmingly common case is a single-property Lead with no portfolio deal at all, and this
 * method returns an empty `PortfolioDealSiblings` for it — never an exception, and never a
 * partially-populated one. The client renders NOTHING in that case (not an empty card), so "no
 * portfolio deal" must be cheap and boring on both sides.
 *
 * @see PortfolioDealSelector.cls (the portfolio-deal-rooted reads for both methods)
 * @see PortfolioDealService.cls (the only WRITER of Portfolio_Deal__c)
 * @see LeadSelector.selectPackageAnchorById / OpportunitySelector.selectPackageAnchorById
 *      (the two anchor reads; their method names still say "Package" — see the note above)
 */
public with sharing class PortfolioDealController {

    /** Fixed, generic user-safe message. No platform detail is ever concatenated into it. */
    private static final String READ_FAILURE_MESSAGE =
        'The related properties could not be loaded. Refresh the page or contact your administrator.';

    /**
     * The homepage widget's own failure message.
     *
     * ⚠ DELIBERATELY NOT `READ_FAILURE_MESSAGE`. The two failures are shown in different places to a
     * user doing different things — one is a card on a record they have open, the other is a widget on
     * their homepage — so "the related properties could not be loaded" would be actively misleading on
     * the homepage, where the user is not looking at any property. A shared constant would also make a
     * future re-wording of one message silently re-word the other.
     *
     * ⚠ IT SAYS "PORTFOLIO DEALS" BECAUSE THAT IS WHAT THE CARD IT APPEARS ON IS TITLED, AND THIS IS
     * THE ONE USER-FACING STRING THE SERVER OWNS. The card was renamed four times on 2026-08-17 —
     * `Recent Packages` -> `Recent Portfolios` (RETRACTED) -> `Portfolio Deals` (RETRACTED) ->
     * `Property Packages` (settled) — and then a FIFTH time on 2026-08-18, back to `Portfolio Deals`,
     * by the rename program below. This constant was re-worded with it every time.
     *
     * 🔴 THE 2026-08-17 RETRACTION OF "Portfolio Deals" IS SPENT, NOT REVERSED BY TASTE, AND THE
     * DIFFERENCE MATTERS. It was retracted because on that day the words collided with a live
     * `Opportunity` STAGE of exactly that name, belonging to a manual, dormant legacy feature that
     * answered a DIFFERENT QUESTION — "which seller's deal bundle is this part of?" — where this
     * widget answers "which inbound broker emails arrived, and what did they carry?". A homepage card
     * whose title read as a deal STAGE, listing rows that are not deals, was a permanent misread.
     * ⚠ THAT LEGACY FEATURE IS NOW RETIRED OUTRIGHT (phases A1-A3 of this program: the stage value,
     * path step, funnel stage list and FLS grants, then the Opportunity fields themselves), so the
     * collision it was retracted for NO LONGER EXISTS, and phase B took the freed name into the schema
     * on purpose. The retraction was contingent on a fact that has since been removed — it is not a
     * standing ban, and reviving it would now be the error.
     *
     * 🔴 WHAT SURVIVES THE REVIVAL, AND IT IS THE ONLY PART THAT EVER MATTERED: the two questions
     * above are still SEPARATE FACTS. `Portfolio_Deal__c` is pipeline-derived — one broker email to
     * many records — and a revived seller-bundle requirement must get its OWN new field rather than a
     * repurposing of this one, no matter how well the NAME now seems to fit it. The name fitting is
     * exactly the trap: it fits both questions in English and answers only one of them in this org.
     * `LeadConvertService.applyDealFields` carries the long-form version of this rule at the
     * assignment itself, and it is written to be independent of what either concept is called.
     *
     * ⚠ THIS WORDING IS PINNED ON THREE SIDES AT ONCE — the card title, the homepage component's own
     * `GENERIC_ERROR`, and this class's test. Move it only as part of a program that owns the
     * vocabulary, never by a local edit.
     *
     * ⚠ AND THE 2026-08-17 CLAIM THAT THE DIVERGENCE WAS "SCOPED TO DISPLAY TEXT" IS NOW FALSE AND
     * MUST NOT BE RESTORED. That paragraph said every API name behind the feature deliberately kept
     * "Package" — `getRecentPackages`, `RecentPackageRow`, `PropertyPackageSelector.selectRecent`,
     * `Property_Package__c`, the client bundle — and that a label changing four times at zero schema
     * cost was the return on it. Phase B4 renamed all of them. The label and the schema now agree,
     * which is what the program was for; a future reader finding this comment should not go looking
     * for a divergence that was closed on purpose.
     */
    private static final String RECENT_READ_FAILURE_MESSAGE =
        'Portfolio deals could not be loaded. Refresh the page or contact your administrator.';

    /**
     * How many portfolio deals the homepage widget shows.
     *
     * 🔴 FIXED AND INTERNAL — `getRecentPortfolioDeals()` takes NO ARGUMENT, matching
     * `LeadFunnelController.getFunnel()` and its own private `RECENT_LIMIT`. A client-supplied limit
     * would be a caller-controlled bound on a `WITH USER_MODE` query from an `@AuraEnabled` method,
     * i.e. an unbounded read one parameter away, for a widget that has exactly one placement and one
     * correct size.
     *
     * ⚠ THIS IS THE FEATURE'S ONLY TRUNCATION POINT, AND IT MUST STAY THAT WAY. The homepage widget
     * deliberately performs NO client-side `.slice()`: this widget exists because a second truncation
     * layer downstream of a server cutoff is exactly what hid these rows in `recentLeads`.
     */
    @TestVisible
    private static final Integer RECENT_LIMIT = 5;

    /**
     * The OTHER Leads and Opportunities that arrived on the same inbound broker email as
     * `recordId`, with `recordId` itself excluded.
     *
     * @param recordId A Lead Id or an Opportunity Id (whichever record page the card is on). Null,
     *                 or an Id of any other object type, yields an empty result.
     * @return The portfolio deal header plus its sibling rows; an EMPTY result (never null, never an
     *         exception) when there is no portfolio deal, it has no other members, or the Id is
     *         not one this card serves.
     * @throws AuraHandledException with a fixed, user-safe message on any read failure — most
     *         plausibly a `QueryException` from `WITH USER_MODE` when the running user has no FLS
     *         on `Portfolio_Deal__c`.
     * @example
     * // LWC: import getSiblingRecords from
     * //   '@salesforce/apex/PortfolioDealController.getSiblingRecords';
     */
    @AuraEnabled(cacheable=true)
    public static PortfolioDealSiblings getSiblingRecords(Id recordId) {
        try {
            PortfolioDealSiblings result = new PortfolioDealSiblings();
            if (recordId == null) {
                return result;
            }

            Id portfolioDealId = resolvePortfolioDealId(recordId);
            if (portfolioDealId == null) {
                // No portfolio deal, or an object this card does not serve. The common case.
                return result;
            }

            Portfolio_Deal__c deal = PortfolioDealSelector.selectWithMembersById(portfolioDealId);
            if (deal == null) {
                // A stale lookup, or a row the user cannot see. Render nothing.
                return result;
            }

            result.portfolioDealId = deal.Id;
            result.portfolioDealName = deal.Name;
            result.portfolioDealUrl = recordUrl(SOBJECT_PORTFOLIO_DEAL, deal.Id);
            result.siblings = buildSiblings(deal, recordId);
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PortfolioDealController.getSiblingRecords: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * The `RECENT_LIMIT` most recently created portfolio deals, newest first, each with its own live
     * member counts — the payload for the Lead Funnel homepage widget.
     *
     * ONE QUERY, CONSTANT IN ROW COUNT AND IN MEMBER COUNT. The member counts are `.size()` on the
     * relationship subqueries the selector already fetched, so a portfolio deal with 10 members costs
     * exactly what one with none costs.
     *
     * ⚠ `.size()` ON AN ALREADY-FETCHED CHILD LIST IS THE ESTABLISHED PATTERN HERE — see
     * `buildSiblings` above, which iterates the same two collections. It is deliberately NOT an
     * aggregate subquery used as a scalar (`SELECT COUNT() ...` inline), a shape that appears nowhere
     * in this codebase and would introduce a new one to answer a question the rows already answer.
     *
     * @return Up to `RECENT_LIMIT` rows, newest first. EMPTY when the org has no portfolio deals yet
     *         — never null, and never an exception, because an org that has received no
     *         multi-property email is the ordinary starting state, not a failure.
     * @throws AuraHandledException with a fixed, user-safe message on any read failure — most
     *         plausibly a `QueryException` from `WITH USER_MODE` when the running user has no FLS on
     *         `Portfolio_Deal__c`.
     * @example
     * // LWC: import getRecentPortfolioDeals from
     * //   '@salesforce/apex/PortfolioDealController.getRecentPortfolioDeals';
     */
    @AuraEnabled(cacheable=true)
    public static List<RecentPortfolioDealRow> getRecentPortfolioDeals() {
        try {
            List<RecentPortfolioDealRow> rows = new List<RecentPortfolioDealRow>();
            for (Portfolio_Deal__c deal : PortfolioDealSelector.selectRecent(RECENT_LIMIT)) {
                rows.add(new RecentPortfolioDealRow(deal));
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PortfolioDealController.getRecentPortfolioDeals: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(RECENT_READ_FAILURE_MESSAGE);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DISPATCH
    // ═══════════════════════════════════════════════════════════════════════════

    private static final String SOBJECT_LEAD = 'Lead';
    private static final String SOBJECT_OPPORTUNITY = 'Opportunity';
    private static final String SOBJECT_PORTFOLIO_DEAL = 'Portfolio_Deal__c';

    /**
     * Resolve the portfolio deal this record belongs to, dispatching on the Id's own SObject type.
     *
     * 🔴 THIS METHOD IS THE OBJECT-AGNOSTICISM. It is the ONLY place in the feature (client or
     * server) that names `Lead` or `Opportunity`, which is why one LWC bundle can serve both
     * record pages. See the class header before adding a third object.
     *
     * ⚠ THE TWO SELECTOR METHODS IT CALLS ARE STILL NAMED `selectPackageAnchorById`. Phase B4
     * repointed `LeadSelector` and `OpportunitySelector` at `Portfolio_Deal__c` without renaming
     * their own public members — five permission-set headers cite those method names as the
     * justification for an FLS grant. They return `Portfolio_Deal__c`; read the query, not the name.
     *
     * @param recordId The record page's Id.
     * @return Its `Portfolio_Deal__c`, or null when it has none or is not a served type.
     */
    private static Id resolvePortfolioDealId(Id recordId) {
        SObjectType recordType = recordId.getSObjectType();

        if (recordType == Lead.SObjectType) {
            List<Lead> rows = LeadSelector.selectPackageAnchorById(recordId);
            return rows.isEmpty() ? null : rows[0].Portfolio_Deal__c;
        }
        if (recordType == Opportunity.SObjectType) {
            List<Opportunity> rows = OpportunitySelector.selectPackageAnchorById(recordId);
            return rows.isEmpty() ? null : rows[0].Portfolio_Deal__c;
        }
        // An allow-list, not a chain of guesses — see the class header. A placement on a third
        // object renders nothing rather than erroring on someone's record page.
        return null;
    }

    /**
     * Map the portfolio deal's two member collections to display rows, EXCLUDING the record the card
     * is on.
     *
     * ⚠ THE EXCLUSION IS DONE HERE, IN APEX, NOT IN THE QUERY, and that is a readability choice
     * with a testable consequence: one `!= recordId` comparison covers both object types, whereas
     * filtering in SOQL would need a bind inside each subquery and would put the rule in two
     * places. `PortfolioDealControllerTest` asserts it from both a Lead anchor and an
     * Opportunity anchor for exactly that reason.
     *
     * Order is Leads then Opportunities, each in creation order (the selector's ORDER BY), so a
     * portfolio deal always reads in the sequence the pipeline built it.
     *
     * @param deal     The portfolio deal with both child collections populated.
     * @param recordId The record to exclude.
     * @return The sibling rows; empty when the portfolio deal's only member is the current record.
     */
    private static List<SiblingRow> buildSiblings(Portfolio_Deal__c deal, Id recordId) {
        List<SiblingRow> siblings = new List<SiblingRow>();

        if (deal.Leads__r != null) {
            for (Lead l : deal.Leads__r) {
                if (l.Id != recordId) {
                    siblings.add(new SiblingRow(l.Id, l.Name, LEAD_LABEL,
                        recordUrl(SOBJECT_LEAD, l.Id), l.Status, l.Property_Address__c));
                }
            }
        }
        if (deal.Opportunities__r != null) {
            for (Opportunity o : deal.Opportunities__r) {
                if (o.Id != recordId) {
                    siblings.add(new SiblingRow(o.Id, o.Name, OPPORTUNITY_LABEL,
                        recordUrl(SOBJECT_OPPORTUNITY, o.Id), o.StageName, o.Property_Address__c));
                }
            }
        }
        return siblings;
    }

    /**
     * The objects' own translated labels, so the card says whatever the org calls them rather than
     * a hardcoded English string. A describe costs no SOQL.
     */
    private static final String LEAD_LABEL = Lead.SObjectType.getDescribe().getLabel();
    private static final String OPPORTUNITY_LABEL = Opportunity.SObjectType.getDescribe().getLabel();

    /**
     * A Lightning record URL.
     *
     * ⚠ Built SERVER-side on purpose. The client must not compose one, because doing so needs the
     * object's API name — the single thing this design keeps away from the component.
     *
     * @param objectApiName The object's API name.
     * @param recordId      The record.
     * @return e.g. `/lightning/r/Lead/00Q.../view`.
     */
    private static String recordUrl(String objectApiName, Id recordId) {
        return '/lightning/r/' + objectApiName + '/' + recordId + '/view';
    }

    /**
     * Build a user-safe `AuraHandledException` carrying `msg` as its display message
     * (`AuraHandledException` otherwise surfaces a generic "Script-thrown exception" to the
     * client). The repo-standard `ahe()` helper — matches `LeadFunnelController`.
     *
     * @param msg The user-facing message.
     * @return The exception to throw.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The card's whole payload. `portfolioDealId` null is the "render nothing" signal, and
     * `siblings` is ALWAYS a list — never null — so the client needs no defensive checks of its own.
     *
     * ⚠ ALL THREE PROPERTY NAMES CHANGED IN PHASE B4 (`packageId` / `packageName` / `packageUrl`).
     * They are WIRE names: the record-page component reads them by name off the Apex response, so
     * this is a breaking client contract change, not an internal rename. The two sides must deploy
     * together.
     */
    public class PortfolioDealSiblings {
        @AuraEnabled public String portfolioDealId;
        @AuraEnabled public String portfolioDealName;
        @AuraEnabled public String portfolioDealUrl;
        @AuraEnabled public List<SiblingRow> siblings = new List<SiblingRow>();
    }

    /**
     * One other record from the same email. `objectLabel` and `recordUrl` are supplied by the
     * server precisely so the client never derives an object name.
     */
    public class SiblingRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String recordUrl;
        /** `Lead.Status` or `Opportunity.StageName` — whichever this row is. */
        @AuraEnabled public String status;
        /**
         * The property address, shown as a second line under the name link (added 2026-08-19).
         *
         * 🔴 NULL IS NORMAL ON BOTH OBJECT TYPES — AND FOR TWO COMPLETELY DIFFERENT REASONS. The two
         * sides are NOT the same kind of field, and every consumer of this member has to survive
         * both:
         *   • `Lead.Property_Address__c` is a plain, nullable Text(255), WRITTEN by the Broker
         *     Protection LLM extraction step. It is blank whenever the extraction found no address
         *     — an ordinary outcome, not a failure.
         *   • `Opportunity.Property_Address__c` is a READ-ONLY FORMULA (`Property__r.Address__c`,
         *     `formulaTreatBlanksAs = BlankAsBlank`). It is blank for as long as the Opportunity's
         *     `Property__c` lookup is empty, and it self-corrects if the Property is re-addressed
         *     later.
         *
         * ⚠ THE FORMULA HALF CHANGES HOW THIS IS TESTED, which is the practical cost of the
         * asymmetry and the reason it is written down here rather than left to be rediscovered:
         * `opp.Property_Address__c = '...'` DOES NOT COMPILE (a formula field is not writable), and
         * the value does not exist on an in-memory sObject at all — formulas are computed at query
         * time. A test must create a `Property__c` with `Address__c`, point `Opportunity.Property__c`
         * at it, and assert against the RE-QUERIED row. An assertion against the pre-insert sObject
         * is vacuously wrong. Conversely the Opportunity NULL case is free (just do not link a
         * Property), while the LEAD null case must null the field explicitly — `TestDataFactory
         * .createLeads` always populates it.
         *
         * ⚠ The client renders NO ELEMENT AT ALL when this is blank (a gated template, not an empty
         * line and not the string "null"). Do not "help" by substituting a placeholder or a fallback
         * to another field here — that was explicitly excluded from the design.
         */
        @AuraEnabled public String propertyAddress;

        private SiblingRow(Id id, String name, String objectLabel, String recordUrl, String status,
                String propertyAddress) {
            this.id = id;
            this.name = name;
            this.objectLabel = objectLabel;
            this.recordUrl = recordUrl;
            this.status = status;
            this.propertyAddress = propertyAddress;
        }
    }

    /**
     * One row of the homepage widget: a portfolio deal, plus how many live records came off its
     * email.
     *
     * ═══ 🔴 A SEPARATE DTO FROM `SiblingRow` / `PortfolioDealSiblings`, DELIBERATELY ═══
     * Those two are shaped for *"the siblings of one specific record"* — `SiblingRow` carries
     * `objectLabel` and `status`, which describe A MEMBER, and `PortfolioDealSiblings` carries exactly
     * one portfolio deal. This row describes A PORTFOLIO DEAL and has no member to label or status to
     * report; reusing either would mean shipping two fields that are meaningless here (and that a
     * reader would then try to populate) while still missing every field the widget actually needs.
     * Two questions, two shapes.
     *
     * ⚠ ONLY THE APEX TYPE NAME CHANGED IN PHASE B4 (`RecentPackageRow`) — every PROPERTY name below
     * was already object-neutral, so the homepage widget's wire payload is byte-identical across the
     * rename and its columns need no client change beyond the import path.
     *
     * ⚠ `propertyCount` AND `leadCount` / `opportunityCount` CAN LEGITIMATELY DISAGREE — do NOT
     * "fix" a mismatch (design residual R9). `Property_Count__c` is a fact about the EMAIL, recorded
     * once by `PortfolioDealService` and never revised. The two member counts are facts about the
     * DATABASE NOW: they are row-visibility-scoped (`with sharing`), they exclude converted Lead husks,
     * and a property that failed to route never produced a member at all. A row can honestly read
     * "3 properties · 2 Leads · 0 Opportunities". They answer different questions.
     */
    public class RecentPortfolioDealRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        /** Server-built, for the same reason as `SiblingRow.recordUrl` — see `recordUrl()`. */
        @AuraEnabled public String recordUrl;
        /** `Property_Count__c` — properties named in the source email. See the R9 note above. */
        @AuraEnabled public Decimal propertyCount;
        @AuraEnabled public String brokerName;
        @AuraEnabled public String brokerEmail;
        /**
         * What the widget DISPLAYS as "Received". NULLABLE — `parseSentDatetime` fails on some
         * senders' headers — which is precisely why the ordering is on `createdDate` instead, in the
         * selector's `ORDER BY`. See `PortfolioDealSelector.selectRecent`.
         */
        @AuraEnabled public Datetime receivedDateTime;
        /**
         * The sort key, sent to the client ONLY so the widget can show a relative age when
         * `receivedDateTime` is null. ⚠ The client must not re-sort on it: the order it arrives in IS
         * the order, fixed server-side.
         */
        @AuraEnabled public Datetime createdDate;
        /** OPEN Lead members only — the selector filters `IsConverted = false`. */
        @AuraEnabled public Integer leadCount;
        @AuraEnabled public Integer opportunityCount;

        private RecentPortfolioDealRow(Portfolio_Deal__c deal) {
            this.id = deal.Id;
            this.name = deal.Name;
            this.recordUrl = recordUrl(SOBJECT_PORTFOLIO_DEAL, deal.Id);
            this.propertyCount = deal.Property_Count__c;
            this.brokerName = deal.Broker_Name__c;
            this.brokerEmail = deal.Broker_Email__c;
            this.receivedDateTime = deal.Received_DateTime__c;
            this.createdDate = deal.CreatedDate;
            // 🔴 NULL-GUARDED, matching `buildSiblings`. A zero-row child subquery arrives as an EMPTY
            // list rather than null (pinned by
            // PortfolioDealSelectorTest.selectWithMembersById_dealWithNoMembersReturnsEmptyCollectionsNotNull),
            // but a memberless portfolio deal is a real accepted state (design R6) and an NPE on the
            // homepage would blank all five rows over one of them.
            this.leadCount = deal.Leads__r == null ? 0 : deal.Leads__r.size();
            this.opportunityCount = deal.Opportunities__r == null ? 0 : deal.Opportunities__r.size();
        }
    }
}
