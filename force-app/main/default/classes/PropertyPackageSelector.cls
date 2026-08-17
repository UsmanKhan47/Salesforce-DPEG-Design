/**
 * Selector for `Property_Package__c` — the FIRST and ONLY SOQL against this object in the
 * application. Every future read of it belongs here, exactly as `AccountSelector` (2026-08-02),
 * `OpportunityContactRoleSelector` (2026-08-03) and `PropertySelector` (Tranche 5A) were each
 * created as the first read of their own object rather than inlined into a caller
 * (.claude/rules/apex-layering-rule.md: "All SOQL must live in Selector classes").
 *
 * Consumers (both via `PropertyPackageController`, both pure reads):
 *   • `getSiblingRecords` → `selectWithMembersById` — the `c/packageSiblings` card on the Lead and
 *     Opportunity record pages.
 *   • `getRecentPackages` → `selectRecent` — the `c/recentPackages` widget on the Lead Funnel
 *     homepage (added 2026-08-17, design §8).
 *
 * ⚠ BOTH METHODS ARE `WITH USER_MODE` AND BOTH ARE PACKAGE-ROOTED READS WITH CHILD SUBQUERIES, but
 * they are NOT variants of one another and must not be merged into a filtered general method: one
 * fetches ONE package BY ID with its member ROWS (name + status, for a list a human clicks), the
 * other fetches the N MOST RECENT packages with member ID's ONLY, for counts. Collapsing them means
 * the homepage read starts selecting `Lead.Name` / `Lead.Status` / `Opportunity.StageName` it never
 * displays — widening the FLS surface of a read that already governs whether the whole homepage
 * renders (see `selectRecent`'s own note).
 *
 * ═══ 🔴 MODE — `WITH USER_MODE`, DELIBERATELY. DO NOT "CORRECT" THIS TOWARD SYSTEM_MODE. ═══
 * ARCHITECTURE.md §2 carries a long automation-path table of `WITH SYSTEM_MODE` selector methods,
 * and this class is NOT one of them — it is the case that table exists to contrast against. Every
 * read here backs a card on a record page A HUMAN HAS ALREADY OPENED, at their request, showing
 * them data about their own deal. That is the textbook `USER_MODE` read: if the running user has
 * no FLS on `Property_Package__c.Name`, the honest outcome is a failure they can report, and the
 * fix is a permission set — not a selector that quietly reads around them.
 *
 * ⚠ The two arguments that DO justify SYSTEM_MODE elsewhere both fail here, and it is worth
 * naming why so the next reader does not have to re-derive it:
 *   • *"USER_MODE throws rather than degrades, so it could silently disable a feature"* — true,
 *     but the feature IS the human's own page view. There is no automation to disable, no trigger
 *     to roll back, no batch to fail silently at 3am, and no `AsyncApexJob` nobody watches.
 *   • *"Metadata-API-deployed custom fields arrive with no FLS for any profile"* — true of these
 *     fields on day one, which is precisely why the FLS is declared IN-FILE in
 *     `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View` and `Broker_Protection_Access` in the same
 *     change. The remedy for a provisioning gap on a user-requested read is provisioning.
 *
 * ═══ SHARING — `with sharing`, AND NO `without sharing` INNER CLASS. DO NOT ADD ONE. ═══
 * `Property_Package__c` is `sharingModel = ReadWrite` (Decision F1), so there is no sharing
 * boundary for an inner class to escape and nothing here can silently under-read. That is a
 * property of the OBJECT, not of this class: narrowing the OWD to Private would re-open the exact
 * failure shape `InboundEmailStagingSelector.RoutingReads` and `PropertyAssetSelector
 * .AssetCreationReads` exist for, and would need answering as its own question.
 *
 * @see PropertyPackageService.cls (the only WRITER of this object)
 * @see LeadSelector.selectPackageAnchorById / OpportunitySelector.selectPackageAnchorById
 *      (the anchor reads — Lead and Opportunity SOQL stays in Lead's and Opportunity's own
 *      selectors, which is why they are NOT in this class)
 */
public with sharing class PropertyPackageSelector {

    /**
     * One package plus BOTH of its member collections — the Leads and the Opportunities sharing
     * it — in a SINGLE query.
     *
     * ═══ 🔴 WHY ONE QUERY WITH CHILD SUBQUERIES, AND NOT THREE QUERIES ═══
     * The obvious shape is three reads: the package, then `SELECT Id FROM Lead WHERE
     * Property_Package__c = :id`, then the same for Opportunity. This is one read instead, and
     * the reason is layering as much as cost: a Lead query belongs in `LeadSelector` and an
     * Opportunity query belongs in `OpportunitySelector` — "nothing else queries that object" —
     * so three reads would mean scattering this feature's sibling logic across three classes.
     * A relationship subquery has its `FROM Property_Package__c`, so it is legitimately this
     * object's own query, and the whole answer arrives with ONE row consumed from the caller's
     * query budget.
     *
     * ⚠ THE SUBQUERY NAMES ARE THE LOOKUPS' `relationshipName` PLUS `__r` (`Leads__r`,
     * `Opportunities__r`). The field metadata on `Lead.Property_Package__c` /
     * `Opportunity.Property_Package__c` stores the BARE name (`Leads`, `Opportunities`) — that is
     * simply how the field-metadata format expresses it — but SOQL and Apex accessor syntax always
     * append `__r` for a CUSTOM lookup's child relationship, regardless of whether the CHILD object
     * is standard (as here) or custom. Precedent in this repo: `Wire__c`'s lookup to
     * `Disposition__c` carries `relationshipName Wires`, and `DispositionSelector` reads
     * `(SELECT Id FROM Wires__r LIMIT 1)`. Renaming either relationship BREAKS THIS QUERY AT
     * COMPILE TIME — which is the good failure mode, and the reason the field metadata sets them
     * explicitly rather than accepting a default.
     *
     * ⚠ `Property__c` MEMBERS ARE DELIBERATELY NOT SELECTED. The card lists the Leads and deals a
     * human can act on; the Property children are reachable from the package's own record page via
     * the standard related list (design §3 item 3, which is why there is no third LWC). Adding
     * them later is a THIRD SUBQUERY here, not a third query.
     *
     * ═══ 🔴 `WHERE IsConverted = false` ON THE LEADS SUBQUERY — LOAD-BEARING, NOT HYGIENE ═══
     * Added 2026-08-17 (code review C3). Without it EVERY worked asset in a package renders TWICE.
     * The mechanism is not a race or an edge case; it is the only state production produces:
     *   • `LeadConvertService.applyDealFields` carries `Property_Package__c` onto the Opportunity at
     *     conversion, and NOTHING nulls it on the source Lead. So an Opportunity member ALWAYS has
     *     a converted Lead twin still carrying the same package Id — the two rows are one asset.
     *   • The Leads subquery therefore returned the husk alongside the deal, and the card showed
     *     "1002 Multi St · Lead · Converted" directly above "1002 Multi St · Opportunity ·
     *     Underwriting".
     *   • The husk row's URL is unusable anyway: Salesforce ALWAYS auto-redirects
     *     `/lightning/r/Lead/{convertedId}/view` to the converted Contact and there is no way to
     *     suppress it — the same fact `LeadSelector.selectRecent` filters on, for the same reason.
     *   • 🔴 AND IT DEFEATED THE CONTROLLER'S CURRENT-RECORD EXCLUSION. On an Opportunity record
     *     page, `PropertyPackageController.buildSiblings` excludes by comparing Ids, and the deal's
     *     OWN former Lead has a different Id — so the anchor appeared as a "sibling" of itself.
     *     That exclusion cannot be fixed by comparing Ids at all; the husk has to leave the query.
     * ⚠ THE OPPORTUNITIES SUBQUERY GETS NO COUNTERPART FILTER. A closed-lost deal is still a real,
     * clickable deal a human may want to reach from a sibling package member; a converted Lead is
     * not a record at all any more.
     *
     * @see PropertyPackageSelectorTest.aConvertedMemberIsCountedOnceNotTwice (the falsifier — it
     *      runs a REAL `Database.convertLead`, because a fixture that builds the Lead and the
     *      Opportunity independently cannot produce this state and so cannot catch a regression)
     *
     * NOT-FOUND CONTRACT — returns null rather than throwing, unlike the `selectStageRequiredById`
     * fetch-for-use family. This backs a read-only card whose entire job is to render nothing when
     * there is nothing to render, so "no such package" is an ordinary answer, not an error.
     *
     * @param packageId The package to load; null returns null WITHOUT querying.
     * @return The package with `Name` and both child collections populated — the Leads collection
     *         holding OPEN Leads only, see the `IsConverted` note above — or null when the Id is
     *         null or matches no row.
     * @throws System.QueryException when the running user lacks FLS on a selected field
     *         (`WITH USER_MODE` throws rather than degrading — see the class header for why that
     *         is the correct outcome on this path).
     * @example
     * Property_Package__c pkg = PropertyPackageSelector.selectWithMembersById(packageId);
     */
    public static Property_Package__c selectWithMembersById(Id packageId) {
        if (packageId == null) {
            return null;
        }
        List<Property_Package__c> rows = [
            SELECT Id, Name, Property_Count__c,
                   (SELECT Id, Name, Status FROM Leads__r
                    WHERE IsConverted = false
                    ORDER BY CreatedDate ASC, Id ASC),
                   (SELECT Id, Name, StageName FROM Opportunities__r ORDER BY CreatedDate ASC, Id ASC)
            FROM Property_Package__c
            WHERE Id = :packageId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The N most recently created packages, each carrying its own live Lead and Opportunity member
     * ID's — for the `c/recentPackages` homepage widget (added 2026-08-17, design §8).
     *
     * ═══ 🔴 WHY THIS EXISTS AT ALL, AND WHY IT IS NOT A `recentLeads` COLUMN ═══
     * `recentLeads` already shows a Package column (§1–§7 of the design), and it is correct — but it
     * reads through `LeadFunnelController.getFunnel()`, which partitions `LeadSelector.selectRecent(50)`
     * into high/standard priority and concatenates them, after which the client shows the first 5. A
     * package's member Leads have no priority of their own, so three unrelated
     * `Broker_Priority__c = 'High'` Leads can permanently occupy 3 of the 5 visible rows and a
     * package's own Leads fall silently past the cutoff (observed with a direct server call — not a
     * permission, FLS or deploy defect). This query is rooted on `Property_Package__c` with its OWN
     * sort and its OWN cutoff, so it inherits none of that. Do not "simplify" it back into the Lead
     * feed.
     *
     * ═══ 🔴 THE SORT IS `CreatedDate`, NOT `Received_DateTime__c` — DELIBERATE ═══
     * `Received_DateTime__c` is the field the widget DISPLAYS, and it is the wrong field to ORDER BY:
     * it is populated by `ExtractAddressQueueable`'s `parseSentDatetime` and is BLANK whenever that
     * parse fails, so sorting on it puts an unknowable number of packages into a null-ordering
     * position at one end of the list. `CreatedDate` is a guaranteed, monotonic, non-null stamp of the
     * moment `PropertyPackageService.createForEmail` ran (pre-loop, Decision C1), which makes it a
     * faithful proxy for "recently received" that can never produce a null surprise. Display one,
     * sort on the other — and the widget's null fallback (a relative age off `createdDate`) is
     * DISPLAY-ONLY for exactly this reason; it must never influence row order.
     *
     * ═══ 🔴 `WHERE IsConverted = false` ON THE LEADS SUBQUERY — LOAD-BEARING, NOT HYGIENE ═══
     * The identical requirement `selectWithMembersById` documents above, for the identical mechanism:
     * `LeadConvertService.applyDealFields` carries `Property_Package__c` onto the Opportunity at
     * conversion and NOTHING nulls it on the source Lead, so every worked asset exists as BOTH a
     * converted Lead husk AND an Opportunity, both pointing here. Without the filter this widget's
     * `leadCount + opportunityCount` DOUBLE-COUNTS every worked asset — a package of 3 properties
     * whose deals are all live would read "3 Leads · 3 Opportunities" for 3 assets. That is worse than
     * the sibling card's version of the bug: there a human sees two rows and can tell they are one
     * property, whereas here they see only a number and cannot.
     * ⚠ THE OPPORTUNITIES SUBQUERY GETS NO COUNTERPART FILTER — a closed-lost deal is still a real
     * deal that came off this email; a converted Lead is not a record any more.
     *
     * ⚠ MEMBER `Id` ONLY, NEVER `Name` / `Status` / `StageName`. The widget shows COUNTS, not rows,
     * and this query is `WITH USER_MODE`: every field added here becomes a field whose FLS can throw
     * and blank the whole card. Selecting a name "in case the widget wants it later" is how a
     * homepage acquires a new single point of failure for free.
     *
     * ⚠ NO `WHERE` CLAUSE, DELIBERATELY. Every package in the org is a real multi-property email and
     * the newest N are the answer; there is no "active" flag to filter on and no date window (a quiet
     * fortnight should still show the last 5, not an empty card).
     *
     * @param limitCount How many packages to return. Must be a positive Integer — the caller passes a
     *                   fixed internal constant (`PropertyPackageController.RECENT_LIMIT`), never a
     *                   client-supplied value, so there is no untrusted or null input to defend
     *                   against here.
     * @return Up to `limitCount` packages, newest first, each with both child collections populated
     *         (the Leads collection holding OPEN Leads only). EMPTY when the org has no packages —
     *         never null.
     * @throws System.QueryException when the running user lacks FLS on a selected field
     *         (`WITH USER_MODE` throws rather than degrading — see the class header for why that is
     *         the correct outcome on this path).
     * @example
     * for (Property_Package__c pkg : PropertyPackageSelector.selectRecent(5)) {
     *     Integer members = pkg.Leads__r.size() + pkg.Opportunities__r.size();
     * }
     */
    public static List<Property_Package__c> selectRecent(Integer limitCount) {
        return [
            SELECT Id, Name, Property_Count__c, Broker_Name__c, Broker_Email__c,
                   Received_DateTime__c, CreatedDate,
                   (SELECT Id FROM Leads__r WHERE IsConverted = false),
                   (SELECT Id FROM Opportunities__r)
            FROM Property_Package__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT :limitCount
        ];
    }
}
