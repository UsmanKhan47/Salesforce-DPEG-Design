/**
 * Read-only `@AuraEnabled` controller for `Property_Package__c` — the ONE `@AuraEnabled` surface for
 * this object, backing TWO components:
 *
 *   • `getSiblingRecords(Id)` → `c/packageSiblings`, the card that answers, on a Lead or an
 *     Opportunity record page, *"what ELSE arrived on the broker email this record came from?"*
 *   • `getRecentPackages()`  → `c/recentPackages`, the Lead Funnel homepage widget answering
 *     *"which multi-property emails arrived most recently?"* (added 2026-08-17, design §8).
 *
 * ═══ 🔴 WHY THE SECOND METHOD IS HERE AND NOT ON `LeadFunnelController` ═══
 * It sits on the same homepage as `recentLeads`, which is the whole reason the question comes up. It
 * belongs here anyway: `LeadFunnelController`'s `FunnelData` / `LeadRow` DTOs are Lead-shaped end to
 * end, so a `Property_Package__c`-shaped return grafted onto them would mix two objects' concerns in
 * one controller for no reason beyond page adjacency. This class is already the read boundary for
 * this object (as `PropertyPackageSelector` is for its SOQL), and per the P6 read-only-controller
 * precedent a second thin `cacheable=true` method on an existing pure-read controller is a smaller,
 * more honest change than a new file.
 *
 * ⚠ SUPERSEDED 2026-08-17 (same day). This paragraph described `recentLeads`' 'Package' column in the
 * PRESENT tense — *"IT IS NOT A DUPLICATE OF `recentLeads`' PACKAGE COLUMN"*, *"That column reads
 * through `LeadFunnelController.getFunnel()`"*, *"The two surfaces answer different questions and both
 * are wanted."* THERE IS NO SUCH COLUMN ANY MORE: it was removed once this method shipped, because the
 * two were redundant and this one is strictly better. `getRecentPackages()` is now the ONLY homepage
 * surface for package visibility, not the second of two.
 *
 * THE REASONING IS UNCHANGED — it is what justified this method AND then retired the column, so read
 * it as a live constraint rather than as history. That column read through
 * `LeadFunnelController.getFunnel()`, which priority-partitions `LeadSelector.selectRecent(50)` and
 * then shows the first 5 rows; a package's member Leads carry no priority of their own, so unrelated
 * high-priority Leads can occupy the visible rows and push a package past the cutoff entirely
 * (observed with a direct server call — not a permission, FLS or deploy defect). This method reads
 * `Property_Package__c` DIRECTLY, with its own sort and its own cutoff, which is the only way to
 * sidestep an inherited partition rather than patch it.
 *
 * ⚠ SO "DO NOT SIMPLIFY BY MERGING IT BACK" NOW MEANS SOMETHING STRONGER, NOT SOMETHING OBSOLETE:
 * restoring the column would re-parent the read on the very partition this method exists to escape,
 * AND it is no longer a client-only edit — it would mean re-adding `packageId` / `packageName` to
 * `LeadFunnelController.LeadRow` and `Property_Package__c` + the spanning `Property_Package__r.Name`
 * to `LeadSelector.selectRecent`, whose `WITH USER_MODE` SELECT is the whole Lead Funnel homepage's
 * single point of FLS failure. `LeadFunnelControllerTest.getFunnel_leadRowCarriesNoPackageMembers` is
 * the falsifier.
 *
 * ⚠ The per-record question *"what package is THIS record in?"* is still answered — by
 * `getSiblingRecords` above, on the Lead and Opportunity record pages, which the column's removal did
 * not touch. That is a different question from *"what packages arrived?"*, and the retired column was
 * a third, weaker answer to the first one.
 *
 * ═══ LAYER — thin controller, NO service class, DELIBERATELY ═══
 * It holds no SOQL and no business logic: it marshals, delegates to selectors, maps rows to a DTO
 * and maps any failure to a user-safe `AuraHandledException` at the LWC boundary
 * (ARCHITECTURE.md §5). No service layer is introduced, per the P6 read-only-controller precedent
 * — `LeadFunnelController`, `CompetingSubmissionController`, `SellMeterController` and
 * `RentRollController` are all pure reads with nothing to extract, and inventing a
 * `PropertyPackageReadService` that only forwards two calls would add a file, not a boundary.
 * `cacheable=true` because this is a pure read.
 *
 * ═══ 🔴 OBJECT-AGNOSTIC BY SERVER DISPATCH — THE WHOLE POINT OF THIS CLASS ═══
 * The method takes a bare `recordId` and switches on `recordId.getSObjectType()`. THE CLIENT NEVER
 * LEARNS AN OBJECT NAME, which is what lets ONE LWC bundle sit on BOTH record pages.
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
 * `@salesforce/schema/Lead.Property_Package__c` — which breaks object-agnosticism outright, since
 * Opportunity then needs a second import and a branch to choose between them — or a dynamic
 * `${objectApiName}.Property_Package__c`, which works but still needs a SECOND round trip for the
 * siblings plus an intermediate "package known, siblings not yet loaded" state in the component.
 * One Apex call taking only the Id has neither problem.
 *
 * ⚠ THE DISPATCH IS AN ALLOW-LIST, NOT A CHAIN OF GUESSES. An Id of any other type returns an
 * EMPTY result rather than throwing: the component is placed by an admin in App Builder, so a
 * placement on a third object is a configuration mistake that should render nothing, not a red
 * error banner on a deal page. Adding a third object here is a `when` branch plus that object's
 * own `selectPackageAnchorById` — never a new bundle.
 *
 * ═══ TWO QUERIES, NOT THREE, AND NEVER PER-ROW ═══
 * 1. the ANCHOR read — this record's `Property_Package__c` (`LeadSelector` /
 *    `OpportunitySelector`, because SOQL follows the object it queries);
 * 2. the PACKAGE read — the package plus BOTH member collections, in one query, through
 *    relationship subqueries (`PropertyPackageSelector.selectWithMembersById`).
 * A null or unmatched package short-circuits after query 1. Nothing here loops over a query.
 *
 * ═══ EMPTY IS AN ANSWER, NOT AN ERROR ═══
 * The overwhelmingly common case is a single-property Lead with no package at all, and this method
 * returns an empty `PackageSiblings` for it — never an exception, and never a partially-populated
 * one. The client renders NOTHING in that case (not an empty card), so "no package" must be cheap
 * and boring on both sides.
 *
 * @see PropertyPackageSelector.cls (the package-rooted reads for both methods)
 * @see PropertyPackageService.cls (the only WRITER of Property_Package__c)
 * @see lwc/packageSiblings (the single bundle on both record pages)
 * @see lwc/recentPackages (the Lead Funnel homepage widget)
 */
public with sharing class PropertyPackageController {

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
     * ⚠ IT SAYS "PROPERTY PACKAGES" BECAUSE THAT IS WHAT THE CARD IT APPEARS ON IS TITLED, AND THIS IS
     * THE ONE USER-FACING STRING THE SERVER OWNS. The card was renamed three times on 2026-08-17 —
     * `Recent Packages` -> `Recent Portfolios` (RETRACTED) -> `Portfolio Deals` (RETRACTED) ->
     * `Property Packages` (settled) — and this constant was re-worded with it every time.
     * `lwc/recentPackages`'s JS header carries the full chain and is authoritative on the label.
     *
     * 🔴 "Portfolio Deals" WAS RETRACTED FOR A REASON, NOT SUPERSEDED BY TASTE: on the day it shipped it
     * collided with a live `Opportunity` STAGE of exactly that name, belonging to a manual, dormant
     * legacy feature that answered a DIFFERENT QUESTION — "which seller's deal bundle is this part of?"
     * — where this widget answers "which inbound broker emails arrived, and what did they carry?". A
     * homepage card whose title read as a deal STAGE, listing rows that are not deals, was a permanent
     * misread. ⚠ THAT LEGACY FEATURE HAS SINCE BEEN RETIRED OUTRIGHT (Portfolio Deal rename, phases
     * A1-A3: the stage value, path step, funnel stage list and FLS grants, then the Opportunity fields
     * themselves), so the collision no longer exists and this paragraph is HISTORY explaining how the
     * settled name was reached — not a permanent ban. What still holds: the two questions above are
     * separate facts, a revived seller-bundle requirement would need its own new field rather than a
     * repurposing of this pipeline-derived grouping, and this wording is pinned on three sides at once
     * (the card title, `c/recentPackages`' `GENERIC_ERROR`, and this class's test). Move it only as part
     * of the program that owns the vocabulary — never by a local edit reviving a retracted label.
     *
     * ⚠ Every API name behind the feature deliberately keeps "Package" through all four names —
     * `getRecentPackages`, `RecentPackageRow`, `PropertyPackageSelector.selectRecent`,
     * `Property_Package__c`, the `c/recentPackages` bundle — so do NOT read this wording as the start
     * of a rename into the schema; the divergence is scoped to display text, and a label changing
     * four times at zero schema cost is the return on it. The settled name is simply the object's own
     * label, pluralised, which is also why it is now collision-free.
     *
     * 🔴 IT MUST BE RE-WORDED IN LOCKSTEP WITH `c/recentPackages`' OWN `GENERIC_ERROR`, AND THAT IS A
     * VISIBLE DEFECT IF MISSED RATHER THAN A TIDINESS POINT. The component renders
     * `error.body.message` when the server supplies one and falls back to its own constant when it
     * does not, so two different words here and there means the same thing is named "property packages"
     * or "portfolio deals" depending only on which layer failed — and with three prior names in
     * circulation that is now a LIKELIER mistake than it was, not a theoretical one.
     * `getSiblingRecords`' message is NOT in that lockstep — it belongs to a separate record-page card
     * (`c/packageSiblings`, itself titled "Property Package", singular). ⚠ The two cards now share the
     * object's vocabulary ON PURPOSE, but they must keep SEPARATE message constants: a shared one
     * would let a re-wording of the homepage message silently re-word the record-page message, whose
     * wording ("the related properties") is deliberately about a different thing.
     */
    private static final String RECENT_READ_FAILURE_MESSAGE =
        'Property packages could not be loaded. Refresh the page or contact your administrator.';

    /**
     * How many packages the homepage widget shows.
     *
     * 🔴 FIXED AND INTERNAL — `getRecentPackages()` takes NO ARGUMENT, matching
     * `LeadFunnelController.getFunnel()` and its own private `RECENT_LIMIT`. A client-supplied limit
     * would be a caller-controlled bound on a `WITH USER_MODE` query from an `@AuraEnabled` method,
     * i.e. an unbounded read one parameter away, for a widget that has exactly one placement and one
     * correct size.
     *
     * ⚠ THIS IS THE FEATURE'S ONLY TRUNCATION POINT, AND IT MUST STAY THAT WAY. `c/recentPackages`
     * deliberately performs NO client-side `.slice()`: this widget exists because a second truncation
     * layer downstream of a server cutoff is exactly what hid packages in `recentLeads`.
     */
    @TestVisible
    private static final Integer RECENT_LIMIT = 5;

    /**
     * The OTHER Leads and Opportunities that arrived on the same inbound broker email as
     * `recordId`, with `recordId` itself excluded.
     *
     * @param recordId A Lead Id or an Opportunity Id (whichever record page the card is on). Null,
     *                 or an Id of any other object type, yields an empty result.
     * @return The package header plus its sibling rows; an EMPTY result (never null, never an
     *         exception) when there is no package, the package has no other members, or the Id is
     *         not one this card serves.
     * @throws AuraHandledException with a fixed, user-safe message on any read failure — most
     *         plausibly a `QueryException` from `WITH USER_MODE` when the running user has no FLS
     *         on `Property_Package__c`.
     * @example
     * // LWC: import getSiblingRecords from
     * //   '@salesforce/apex/PropertyPackageController.getSiblingRecords';
     */
    @AuraEnabled(cacheable=true)
    public static PackageSiblings getSiblingRecords(Id recordId) {
        try {
            PackageSiblings result = new PackageSiblings();
            if (recordId == null) {
                return result;
            }

            Id packageId = resolvePackageId(recordId);
            if (packageId == null) {
                // No package, or an object this card does not serve. The common case.
                return result;
            }

            Property_Package__c pkg = PropertyPackageSelector.selectWithMembersById(packageId);
            if (pkg == null) {
                // A stale lookup, or a package the user cannot see. Render nothing.
                return result;
            }

            result.packageId = pkg.Id;
            result.packageName = pkg.Name;
            result.packageUrl = recordUrl(SOBJECT_PACKAGE, pkg.Id);
            result.siblings = buildSiblings(pkg, recordId);
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PropertyPackageController.getSiblingRecords: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * The `RECENT_LIMIT` most recently created packages, newest first, each with its own live member
     * counts — the payload for the `c/recentPackages` homepage widget.
     *
     * ONE QUERY, CONSTANT IN PACKAGE COUNT AND IN MEMBER COUNT. The member counts are `.size()` on the
     * relationship subqueries the selector already fetched, so a package with 10 members costs exactly
     * what a package with none costs.
     *
     * ⚠ `.size()` ON AN ALREADY-FETCHED CHILD LIST IS THE ESTABLISHED PATTERN HERE — see
     * `buildSiblings` above, which iterates the same two collections. It is deliberately NOT an
     * aggregate subquery used as a scalar (`SELECT COUNT() ...` inline), a shape that appears nowhere
     * in this codebase and would introduce a new one to answer a question the rows already answer.
     *
     * @return Up to `RECENT_LIMIT` rows, newest first. EMPTY when the org has no packages yet — never
     *         null, and never an exception, because an org that has received no multi-property email
     *         is the ordinary starting state, not a failure.
     * @throws AuraHandledException with a fixed, user-safe message on any read failure — most
     *         plausibly a `QueryException` from `WITH USER_MODE` when the running user has no FLS on
     *         `Property_Package__c`.
     * @example
     * // LWC: import getRecentPackages from
     * //   '@salesforce/apex/PropertyPackageController.getRecentPackages';
     */
    @AuraEnabled(cacheable=true)
    public static List<RecentPackageRow> getRecentPackages() {
        try {
            List<RecentPackageRow> rows = new List<RecentPackageRow>();
            for (Property_Package__c pkg : PropertyPackageSelector.selectRecent(RECENT_LIMIT)) {
                rows.add(new RecentPackageRow(pkg));
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PropertyPackageController.getRecentPackages: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(RECENT_READ_FAILURE_MESSAGE);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DISPATCH
    // ═══════════════════════════════════════════════════════════════════════════

    private static final String SOBJECT_LEAD = 'Lead';
    private static final String SOBJECT_OPPORTUNITY = 'Opportunity';
    private static final String SOBJECT_PACKAGE = 'Property_Package__c';

    /**
     * Resolve the package this record belongs to, dispatching on the Id's own SObject type.
     *
     * 🔴 THIS METHOD IS THE OBJECT-AGNOSTICISM. It is the ONLY place in the feature (client or
     * server) that names `Lead` or `Opportunity`, which is why one LWC bundle can serve both
     * record pages. See the class header before adding a third object.
     *
     * @param recordId The record page's Id.
     * @return Its `Property_Package__c`, or null when it has none or is not a served type.
     */
    private static Id resolvePackageId(Id recordId) {
        SObjectType recordType = recordId.getSObjectType();

        if (recordType == Lead.SObjectType) {
            List<Lead> rows = LeadSelector.selectPackageAnchorById(recordId);
            return rows.isEmpty() ? null : rows[0].Property_Package__c;
        }
        if (recordType == Opportunity.SObjectType) {
            List<Opportunity> rows = OpportunitySelector.selectPackageAnchorById(recordId);
            return rows.isEmpty() ? null : rows[0].Property_Package__c;
        }
        // An allow-list, not a chain of guesses — see the class header. A placement on a third
        // object renders nothing rather than erroring on someone's record page.
        return null;
    }

    /**
     * Map the package's two member collections to display rows, EXCLUDING the record the card is
     * on.
     *
     * ⚠ THE EXCLUSION IS DONE HERE, IN APEX, NOT IN THE QUERY, and that is a readability choice
     * with a testable consequence: one `!= recordId` comparison covers both object types, whereas
     * filtering in SOQL would need a bind inside each subquery and would put the rule in two
     * places. `PropertyPackageControllerTest` asserts it from both a Lead anchor and an
     * Opportunity anchor for exactly that reason.
     *
     * Order is Leads then Opportunities, each in creation order (the selector's ORDER BY), so a
     * package always reads in the sequence the pipeline built it.
     *
     * @param pkg      The package with both child collections populated.
     * @param recordId The record to exclude.
     * @return The sibling rows; empty when the package's only member is the current record.
     */
    private static List<SiblingRow> buildSiblings(Property_Package__c pkg, Id recordId) {
        List<SiblingRow> siblings = new List<SiblingRow>();

        if (pkg.Leads__r != null) {
            for (Lead l : pkg.Leads__r) {
                if (l.Id != recordId) {
                    siblings.add(new SiblingRow(l.Id, l.Name, LEAD_LABEL,
                        recordUrl(SOBJECT_LEAD, l.Id), l.Status));
                }
            }
        }
        if (pkg.Opportunities__r != null) {
            for (Opportunity o : pkg.Opportunities__r) {
                if (o.Id != recordId) {
                    siblings.add(new SiblingRow(o.Id, o.Name, OPPORTUNITY_LABEL,
                        recordUrl(SOBJECT_OPPORTUNITY, o.Id), o.StageName));
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
     * The card's whole payload. `packageId` null is the "render nothing" signal, and `siblings` is
     * ALWAYS a list — never null — so the client needs no defensive checks of its own.
     */
    public class PackageSiblings {
        @AuraEnabled public String packageId;
        @AuraEnabled public String packageName;
        @AuraEnabled public String packageUrl;
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

        private SiblingRow(Id id, String name, String objectLabel, String recordUrl, String status) {
            this.id = id;
            this.name = name;
            this.objectLabel = objectLabel;
            this.recordUrl = recordUrl;
            this.status = status;
        }
    }

    /**
     * One row of the homepage widget: a package, plus how many live records came off its email.
     *
     * ═══ 🔴 A SEPARATE DTO FROM `SiblingRow` / `PackageSiblings`, DELIBERATELY ═══
     * Those two are shaped for *"the siblings of one specific record"* — `SiblingRow` carries
     * `objectLabel` and `status`, which describe A MEMBER, and `PackageSiblings` carries exactly one
     * package. This row describes A PACKAGE and has no member to label or status to report; reusing
     * either would mean shipping two fields that are meaningless here (and that a reader would then
     * try to populate) while still missing every field the widget actually needs. Two questions, two
     * shapes.
     *
     * ⚠ `propertyCount` AND `leadCount` / `opportunityCount` CAN LEGITIMATELY DISAGREE — do NOT
     * "fix" a mismatch (design residual R9). `Property_Count__c` is a fact about the EMAIL, recorded
     * once by `PropertyPackageService` and never revised. The two member counts are facts about the
     * DATABASE NOW: they are row-visibility-scoped (`with sharing`), they exclude converted Lead husks,
     * and a property that failed to route never produced a member at all. A package can honestly read
     * "3 properties · 2 Leads · 0 Opportunities". They answer different questions.
     */
    public class RecentPackageRow {
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
         * selector's `ORDER BY`. See `PropertyPackageSelector.selectRecent`.
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

        private RecentPackageRow(Property_Package__c pkg) {
            this.id = pkg.Id;
            this.name = pkg.Name;
            this.recordUrl = recordUrl(SOBJECT_PACKAGE, pkg.Id);
            this.propertyCount = pkg.Property_Count__c;
            this.brokerName = pkg.Broker_Name__c;
            this.brokerEmail = pkg.Broker_Email__c;
            this.receivedDateTime = pkg.Received_DateTime__c;
            this.createdDate = pkg.CreatedDate;
            // 🔴 NULL-GUARDED, matching `buildSiblings`. A zero-row child subquery arrives as an EMPTY
            // list rather than null (pinned by
            // PropertyPackageSelectorTest.selectWithMembersById_packageWithNoMembersReturnsEmptyCollectionsNotNull),
            // but a memberless package is a real accepted state (design R6) and an NPE on the homepage
            // would blank all five rows over one of them.
            this.leadCount = pkg.Leads__r == null ? 0 : pkg.Leads__r.size();
            this.opportunityCount = pkg.Opportunities__r == null ? 0 : pkg.Opportunities__r.size();
        }
    }
}
