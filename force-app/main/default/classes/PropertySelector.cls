/**
 * Selector for Property__c. Encapsulates ALL SOQL against Property__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live in
 * Selector classes. Nothing else queries that object.").
 *
 * 🔴 THIS IS THE FIRST AND ONLY `Property__c` SOQL IN THE APPLICATION. Measured
 * 2026-08-10: repo-wide there was NO production query against `Property__c` at all —
 * only eight statements inside `LeadConvertServiceTest` / `SellMeterControllerTest`.
 * `Property__c` is the root of the acquisition graph (ARCHITECTURE.md §1) and had no
 * selector, so every future Property read belongs here. Same argument `AccountSelector`
 * (2026-08-02) and `OpportunityContactRoleSelector` (2026-08-03) won.
 *
 * Consumers:
 *   - PropertyAssetService.ensureOnClosedWon -> selectAssetSeedByIds
 *   - DealFolderService                      -> selectFolderStateByIds   (added 2026-08-11;
 *     re-keyed 2026-08-27 from 'Closed Won' entry to CLAIM-STAGE entry — see that class's
 *     CLAIM_STAGES. The QUERY is unchanged; only how often and how early it runs moved.)
 *   - DealFolderSweepBatch.start             -> queryFolderSweep         (added 2026-08-11)
 *   - LeadConvertService.createProperties    -> selectByNormalizedAddresses (WS3, 2026-08-30)
 *
 * ⚠ ALL FOUR METHODS ARE `WITH SYSTEM_MODE` INSIDE A `private without sharing` INNER CLASS, AND
 * THE THREE INNER CLASSES ARE DELIBERATELY SEPARATE — `AssetCreationReads`, `FolderCreationReads`
 * and `ReuseLookupReads`. They could be merged and must not be: each carries its own argument for
 * why it escapes sharing, and one shared class would let a future read borrow whichever argument
 * happened to be written first. Read the method's Javadoc, never the class's.
 * ⚠ WS3 (2026-08-30) added the THIRD one rather than putting `byNormalizedAddresses` into
 * `FolderCreationReads`, whose "under-read mints a duplicate" argument it superficially shares.
 * The two duplicates are not the same object: `FolderCreationReads` prevents a duplicate SHAREPOINT
 * FOLDER — an external, unrecoverable write — while this one prevents a duplicate `Property__c`
 * row, which is a Salesforce record an admin can merge. Borrowing the stronger argument for the
 * weaker case is exactly the drift the separation exists to stop.
 *
 * ── ⚠ WHY THIS CLASS EXISTS AT ALL, RATHER THAN A METHOD ON `OpportunitySelector` ──
 * The Tranche 5 design (§2.7 step 3) proposed reading the same two values through the
 * parent path on Opportunity (`SELECT Property__r.Name, Property__r.Asset_Type__c FROM
 * Opportunity`), on the stated grounds that "`Trigger.new` does not carry parent-path
 * fields, so this query is unavoidable". The query is indeed unavoidable; WHICH object it
 * runs against is not, and that half was not examined. `Trigger.new` DOES carry
 * `Opportunity.Property__c` — it is an ordinary field on the record — so the caller
 * already holds every Property Id it needs and re-reading Opportunity to reach Property
 * fields is an indirection that buys nothing. Two further reasons, in order of force:
 *
 *   1. `OpportunitySelector`'s header carries an explicit "🔴 NONE OF THEM MAY BE
 *      WIDENED" warning over its eleven `USER_MODE` methods, with exactly one
 *      `SYSTEM_MODE` exception argued for one automation path. Adding a second
 *      automation-path method there dilutes a warning that is doing real work.
 *   2. Keying on distinct Property Ids DEDUPES for free. Two Opportunities closing
 *      against the same Property return one row here and two rows there.
 *
 * ── MODE — `WITH SYSTEM_MODE`. ⚠ SHARING IS A SEPARATE DECISION, ARGUED BELOW ──
 * `SYSTEM_MODE` lifts CRUD and FLS ONLY. It does NOT touch sharing. Conflating the two
 * is the error recorded as D25 in `agent-output/stage-by-stage-decisions.md` and paid for
 * on 2026-08-08 in `InboundEmailStagingSelector`, so each half is argued on its own.
 *
 * NOT-FOUND CONTRACT — read-for-display: the caller iterates the result and builds one
 * asset per row RETURNED, never one per Id passed in. A Property that does not come back
 * (hard-deleted between the stage change and this read) silently produces no asset rather
 * than a nameless one. `Property_Asset__c.Name` is a mandatory Text name field, so a
 * fabricated row would fail the whole insert and, with it, the deal close.
 *
 * @see InboundEmailStagingSelector.RoutingReads (the `private without sharing` precedent)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class PropertySelector {

    /**
     * The two values `PropertyAssetService` copies onto a new `Property_Asset__c` when a
     * deal reaches Closed Won: the property's `Name` (which becomes the asset's Name) and
     * its `Asset_Type__c` (which is MAPPED, never copied, onto the asset's
     * `Property_Type__c` — see that service for why).
     *
     * ⚠ THE FIELD SET IS DELIBERATELY MINIMAL AND MUST STAY THAT WAY. This query runs on
     * EVERY Closed Won org-wide, inside an after-update trigger, and its caller's insert is
     * all-or-none — so every field added here becomes a new way for a deal close to fail.
     * Two fields are needed; two fields are selected.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION-PATH read in the ARCHITECTURE.md §2 sense: nobody asked for it. It
     * happens on the running user's behalf while the platform turns a won deal into a
     * managed asset. `WITH USER_MODE` does not degrade, it THROWS, and the throw escapes an
     * after-update trigger as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` — rolling back the deal
     * close itself. That is verbatim the `TaskSelector.selectByTransactionDealIds`
     * production incident (82 Day-0 Tasks rolled back by one FLS denial).
     *
     * The exposure is measured, not hypothetical. The Opportunity update that fires this is
     * reachable two ways, and BOTH run as a principal who may hold nothing on `Property__c`:
     *   - `StageAdvanceService.NEXT_STAGE` maps `About to Close ⇒ Closed Won`, so any deal
     *     driver can drive it. ⚠ AMENDED 2026-09-02: this line also named
     *     `Under Contract (PSA) ⇒ Closed Won`, which was repointed to `About to Close` when the
     *     transaction gate landed. ONE key instead of two changes the EXPOSURE not at all — a
     *     deal driver still reaches Closed Won through the surviving key, which is the only
     *     thing this paragraph is claiming; and
     *   - the `Transaction_Complete_Close` flow writes `StageName = 'Closed Won'` with **no
     *     `<runInMode>` element**, i.e. DefaultMode, i.e. as the TRANSACTIONS persona who
     *     flipped the `Transaction__c` to Closed.
     * Every DPEG persona sits on `Minimum Access - Salesforce`, which grants no FLS at all.
     *
     * 🔴 ── AND SHARING, SEPARATELY — SEE THE `AssetCreationReads` INNER CLASS ──
     * `Property__c` is `sharingModel = Private`. Under `with sharing` a principal outside the
     * four sets that grant `viewAllRecords` gets ZERO ROWS, no asset is built, and the deal
     * closes looking perfectly healthy. The SOQL therefore lives in the `without sharing`
     * inner class; this method is the wrapper.
     *
     * BULK read (Set&lt;Id&gt;): called ONCE per trigger chunk regardless of deal count.
     * Never call it per record.
     *
     * @param propertyIds Property Ids to load (bound with IN); null/empty-safe.
     * @return Property__c records with Id, Name and Asset_Type__c populated; an empty list
     *         when the input is null/empty (never null).
     * @example
     * for (Property__c p : PropertySelector.selectAssetSeedByIds(propertyIds)) { ... }
     */
    public static List<Property__c> selectAssetSeedByIds(Set<Id> propertyIds) {
        if (propertyIds == null || propertyIds.isEmpty()) {
            return new List<Property__c>();
        }
        return new AssetCreationReads().assetSeedByIds(propertyIds);
    }

    /**
     * The SharePoint deal-folder state of a set of properties: the folder's Graph item id and URL,
     * the integration status, and the `Name` the folder is derived from.
     *
     * Called by `DealFolderService` on BOTH of its paths — once synchronously per trigger chunk to
     * decide what to stamp `Pending` and whether to enqueue anything at all, and once again inside
     * the async job immediately before the callouts.
     *
     * ⚠ 2026-08-27 — THE SYNCHRONOUS CALLER MOVED EARLIER IN THE PIPELINE, and both halves of the
     * justification below got STRONGER rather than weaker. The claim now fires on entry to any of
     * `DealFolderService.CLAIM_STAGES`, so this read runs on essentially every deal at its FIRST
     * forward step, driven by any deal driver in the org — not on the subset that closed, driven by
     * the closing desk. A `USER_MODE` throw here would therefore roll back a Begin Review click
     * rather than a close, and a sharing-filtered result would mint duplicates far more often. The second read is not redundant: it is the
     * IDEMPOTENCY GUARD evaluated at the moment of work, which is what makes a concurrent second
     * close, a chained continuation and a sweep retry all converge on ONE folder.
     *
     * FIELD SET — `Name` is the folder name source (sanitized by `DealFolderService`);
     * `SharePoint_Folder_ID__c` is the guard; `SharePoint_Folder_URL__c` and
     * `SharePoint_Folder_Status__c` are read so the stamp can be written WITHOUT a second read and
     * so an already-correct row can be left out of the DML entirely.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION-PATH read in the ARCHITECTURE.md §2 sense: nobody asked for it. It happens on
     * the running user's behalf while the platform files the documents of a deal ENTERING A CLAIM
     * STAGE (`DealFolderService.CLAIM_STAGES`). All four
     * SharePoint fields are created in THIS SAME CHANGE, and a Metadata-API-deployed custom field
     * arrives with NO field permissions for ANY profile, **System Administrator included**.
     * `WITH USER_MODE` does not degrade, it THROWS (`System.QueryException: No such column ...`,
     * which is how the platform reports an FLS denial). On the synchronous path that throw escapes
     * an after-update trigger as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolls back the deal's
     * FIRST FORWARD STAGE ADVANCE** — a Begin Review click, not a close, since the 2026-08-27
     * claim-stage move — verbatim the `TaskSelector.selectByTransactionDealIds` production incident,
     * and here it would be caused by the very fields the deploy just created. On the sweep path the
     * same throw kills the recovery engine for the administrator who deployed it.
     *
     * 🔴 ── AND SHARING, SEPARATELY — SEE THE `FolderCreationReads` INNER CLASS ──
     * `SYSTEM_MODE` lifts CRUD and FLS ONLY; it does NOT lift record sharing. Conflating the two is
     * the D25 error this repo has paid for, so the sharing half is argued on its own at that class.
     * It is the more dangerous half here: this is an IDEMPOTENCY GUARD, and a sharing-filtered
     * guard read does not disable the feature — it INVERTS it, minting a duplicate folder.
     *
     * BULK read (Set&lt;Id&gt;): called ONCE per transaction regardless of deal count. Never call it
     * per record.
     *
     * @param propertyIds Property Ids to load (bound with IN); null/empty-safe.
     * @return The matching rows with the four fields populated; an empty list when the input is
     *         null/empty (never null).
     * @example
     * for (Property__c p : PropertySelector.selectFolderStateByIds(propertyIds)) { ... }
     */
    public static List<Property__c> selectFolderStateByIds(Set<Id> propertyIds) {
        if (propertyIds == null || propertyIds.isEmpty()) {
            return new List<Property__c>();
        }
        return new FolderCreationReads().folderStateByIds(propertyIds);
    }

    /**
     * The SharePoint deal-folder RECOVERY QUEUE: every property whose folder is still owed.
     *
     * Backs `DealFolderSweepBatch.start()`, which holds no SOQL of its own per
     * `.claude/rules/apex-layering-rule.md`.
     *
     * 🔴 WHY BOTH `Pending` AND `Failed`, AND WHY NEITHER IS ENOUGH ALONE. `Pending` is written
     * synchronously by the trigger before any callout, so it catches a job that DIED UNCATCHABLY,
     * never ran at all, or — now the LARGEST source of work here — was DEFERRED past
     * `MAX_PROPERTIES_PER_TRANSACTION` or the callout time budget, which every bulk claim-stage
     * entry leaves behind by design. `Failed` is written by `DealFolderFinalizer` or by the
     * service's own error branch, so it catches transient Graph failures plus the TWO remaining
     * credential-refusal routes: (i) the `LOI_Approval` final-rejection field update
     * (`LOI ⇒ Underwriting`, a claim-stage entry) running as the READ-ONLY APPROVER, and (ii)
     * `Transaction_Complete_Close` as a backstop claim at `Closed Won`.
     * ⚠ AMENDED 2026-08-27 — this paragraph used to name "a deal closed by the TRANSACTIONS
     * persona" as *the case this feature must survive*. That whole-persona outage no longer
     * exists: the ordinary claimer is now the human clicking Begin Review, a deal driver on
     * `DPEG_Junior_Analyst_PSG`, which HOLDS the grant. The sweep is still load-bearing, for the
     * reasons above rather than that one. See `DealFolderSweepBatch`'s header.
     * Those rows MUST reach a sweep running as a granted principal.
     * `Created` and `Skipped` are terminal and are excluded BY THE QUERY, which is what makes
     * re-running the sweep free.
     *
     * ⚠ THERE IS DELIBERATELY NO AGE FILTER and no `SharePoint_Folder_ID__c != null` exclusion. The
     * batch must SEE a row that already carries an id in order to CONVERGE it to `Created` at zero
     * callouts — filtering those out would leave a row that succeeded-but-failed-to-stamp in the
     * queue forever, re-selected on every pass.
     *
     * ── MODE and SHARING ── identical to `selectFolderStateByIds` above, plus the sharpest
     * instance of the mode argument: a SCHEDULED batch runs as whichever principal happened to
     * schedule it, and `WITH USER_MODE` would break the entire recovery path for the very
     * administrator who deployed the fields, silently, on day one.
     *
     * @return A locator over the owed rows, oldest first so the longest-waiting deal is served
     *         before the freshest one.
     * @example
     * public Database.QueryLocator start(Database.BatchableContext ctx) {
     *     return PropertySelector.queryFolderSweep();
     * }
     */
    public static Database.QueryLocator queryFolderSweep() {
        return new FolderCreationReads().folderSweepLocator();
    }

    /**
     * WS3 (2026-08-30) — THE PROPERTY-REUSE LOOKUP. Every existing `Property__c` whose stored
     * normalized-address key matches one of the keys supplied, so `LeadConvertService` can LINK a
     * converted deal to a building it already knows about instead of minting a second row for it.
     *
     * ⚠ THE KEY HAS EXACTLY ONE DEFINITION: `PropertyMatchingService.normalizeAddress`. Callers
     * must pass its output and nothing else. Hand-deriving an equivalent string anywhere — in Apex,
     * in a formula, in a script — is the defect this whole workstream exists to prevent: the same
     * building would key two ways and the reuse would silently stop working with nothing to see.
     * A formula field cannot reproduce it either (that method is regex; Salesforce formulas have no
     * regex), which is why `Property__c.Normalized_Address__c` is a STORED Text field written by
     * `LeadConvertService.buildProperty` and by `scripts/backfill-property-normalized-address.apex`.
     *
     * FIELD SET — deliberately TWO fields and no more. `Id` is the only value the caller consumes;
     * `Normalized_Address__c` is selected because the caller must re-key the result BY the matched
     * key (it asked about up to 251 buildings in one call and gets back an unordered list). This
     * query runs on EVERY lead conversion in the org, so every extra field is a new way for a
     * conversion to get more expensive; nothing else is needed and nothing else is selected.
     *
     * ORDER BY CreatedDate ASC, Id ASC — DETERMINISM, NOT COSMETICS. `Normalized_Address__c` is
     * deliberately `unique = false` (the org already holds duplicate Properties — that is the bug
     * being fixed — and a unique index would refuse the backfill), so two rows CAN share a key. The
     * caller keeps the FIRST row per key, which this ordering makes the OLDEST Property: reuse
     * converges on the original record rather than oscillating between duplicates run to run. `Id`
     * breaks a same-millisecond tie so the answer is total, not merely usually-stable.
     *
     * BLANK KEYS ARE STRIPPED HERE AS WELL AS AT THE CALLER, AND THAT BELT-AND-BRACES IS
     * DELIBERATE. `normalizeAddress('')` returns `''`, and an empty key would match every Property
     * whose address was blank — collapsing every addressless deal in the org onto ONE building.
     * That is the single worst outcome this method can produce, it is one careless caller away, and
     * a stripped key costs nothing.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION-PATH read in the ARCHITECTURE.md §2 sense: nobody asked for it. It happens on
     * the converting user's behalf, inside a `Lead` after-update trigger, while the platform turns
     * a qualified lead into a deal. `Normalized_Address__c` is created in THIS SAME CHANGE, and a
     * Metadata-API-deployed custom field arrives with NO field permissions for ANY profile,
     * **System Administrator included**. `WITH USER_MODE` does not degrade, it THROWS
     * (`System.QueryException: No such column ...`, which is how the platform reports an FLS
     * denial) — and from inside that after-update trigger the throw escapes as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolls back the conversion itself**. The user
     * would be told their lead cannot be converted, by the very field the deploy just created.
     * Verbatim the `TaskSelector.selectByTransactionDealIds` production incident.
     *
     * 🔴 ── AND SHARING, SEPARATELY — SEE THE `ReuseLookupReads` INNER CLASS ──
     * `SYSTEM_MODE` lifts CRUD and FLS ONLY; it does NOT lift record sharing. `Property__c` is
     * `sharingModel = Private`, so under `with sharing` this read returns zero rows for a converter
     * who cannot see the earlier Property — and zero rows reads as "no such building", which mints
     * the duplicate this feature exists to prevent. The sharing half is argued at that class.
     *
     * BULK read (Set&lt;String&gt;): called ONCE per `stampConvertedOpportunities` invocation
     * regardless of how many Leads converted. 🔴 NEVER call it per Lead —
     * `LeadConvertServiceTest.stampCostDoesNotScaleWithBatchSize` and
     * `bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities` both exist to fail if it is.
     *
     * @param normalizedAddresses `normalizeAddress` output keys to look up (bound with IN);
     *                            null/empty-safe, and blank members are ignored.
     * @return The matching rows with `Id` and `Normalized_Address__c` populated, oldest first; an
     *         empty list when the input is null/empty/all-blank (never null).
     * @example
     * for (Property__c p : PropertySelector.selectByNormalizedAddresses(keys)) { ... }
     */
    public static List<Property__c> selectByNormalizedAddresses(Set<String> normalizedAddresses) {
        if (normalizedAddresses == null || normalizedAddresses.isEmpty()) {
            return new List<Property__c>();
        }
        Set<String> keys = new Set<String>();
        for (String key : normalizedAddresses) {
            if (String.isNotBlank(key)) {
                keys.add(key);
            }
        }
        if (keys.isEmpty()) {
            return new List<Property__c>();
        }
        return new ReuseLookupReads().byNormalizedAddresses(keys);
    }

    /**
     * 🔴 THE CLOSED-WON ASSET-CREATION READ, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * ═══ WHY — `WITH SYSTEM_MODE` IS NOT ENOUGH ═══
     * `SYSTEM_MODE` lifts FLS and CRUD only; it does NOT lift record sharing. Measured
     * against this repo 2026-08-10:
     *   - `objects/Property__c/Property__c.object-meta.xml` -> `sharingModel = Private`.
     *   - `sharingRules/Property__c.sharingRules-meta.xml` holds ONE rule, an OWNER rule
     *     sharing rows owned by the `Acquisition` QUEUE to `DPEG_Acquisitions_Team`. A
     *     Property created by `LeadConvertService` is owned by whoever converted the Lead,
     *     NOT by the queue, so that rule does not reach it.
     *   - `viewAllRecords = true` on `Property__c` comes from exactly four permission sets:
     *     `DPEG_Acquisitions`, `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`,
     *     `DPEG_Property_View`.
     * `Opportunity` OWD is `ReadWrite`, so ANY user with Edit on Opportunity can set the
     * stage to Closed Won — including one holding none of those four sets.
     *
     * The failure that produces is the WORSE of the two available failures, and that is the
     * whole argument: under `with sharing` this read returns zero rows, the caller builds
     * zero assets, the deal closes cleanly, and the Property Management tree has no root —
     * **byte-identical, from outside, to the bug this feature was built to fix.** By
     * contrast a `SYSTEM_MODE` + `without sharing` read cannot fail quietly.
     *
     * ═══ WHAT THIS DOES NOT WIDEN ═══
     * The two values never reach a user. They are written into a `Property_Asset__c` the
     * running principal may not be able to see, by a service with no return value, on a
     * record they already named by putting it on the deal they just closed. There is no
     * read surface here to leak through.
     *
     * ═══ PRECEDENT ═══
     * Identical in shape and argument to `InboundEmailStagingSelector.RoutingReads` and
     * `LeadSelector.GuestReads`: an automation that must act on ALL matching rows cannot be
     * scoped by an incidental principal's sharing.
     *
     * ═══ SCOPE — AS NARROW AS APEX ALLOWS ═══
     * Inner classes do NOT inherit the outer class's sharing, so this is declared explicitly
     * and `PropertySelector` itself STAYS `with sharing`. It is `private`, so the only way in
     * is the public static wrapper above — nothing outside this file can borrow an unshared
     * read of `Property__c`. Any future user-requested Property read belongs on the outer
     * class with `WITH USER_MODE`, and must not be moved in here for convenience.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new AssetCreationReads()` at the call site.
     */
    private without sharing class AssetCreationReads {

        /**
         * The asset seed values for a set of properties, read without sharing. See
         * `selectAssetSeedByIds` for the field set and the `SYSTEM_MODE` justification, and
         * the enclosing class for the sharing one.
         *
         * @param propertyIds The properties to read; never null/empty (the wrapper guards it).
         * @return The matching rows; empty when none of the Ids resolve.
         */
        private List<Property__c> assetSeedByIds(Set<Id> propertyIds) {
            return [
                SELECT Id, Name, Asset_Type__c
                FROM Property__c
                WHERE Id IN :propertyIds
                WITH SYSTEM_MODE
            ];
        }
    }

    /**
     * 🔴 THE SHAREPOINT DEAL-FOLDER READS, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * ═══ WHY — `WITH SYSTEM_MODE` IS NOT ENOUGH, AND THE TWO HALVES ARE SEPARATE QUESTIONS ═══
     * `SYSTEM_MODE` lifts FLS and CRUD only; it does NOT lift record sharing. The mode half is
     * argued at each public method (new fields, no FLS for anyone, `USER_MODE` throws rather than
     * degrades). This is the sharing half, and it is the more dangerous one. Measured against this
     * repo:
     *   - `objects/Property__c/Property__c.object-meta.xml` -> `sharingModel = Private`.
     *   - `sharingRules/Property__c.sharingRules-meta.xml` holds ONE rule, an OWNER rule sharing
     *     rows owned by the `Acquisition` QUEUE to `DPEG_Acquisitions_Team`. A Property created by
     *     `LeadConvertService` is owned by whoever converted the Lead, NOT by the queue, so that
     *     rule does not reach it.
     *   - `Opportunity` OWD is `ReadWrite`, so ANY user with Edit on Opportunity can drive a deal
     *     into a CLAIM STAGE — including one who can see none of its Property rows.
     *     ⚠ WIDENED 2026-08-27: this used to say "to Closed Won", which described a much smaller
     *     population. Entering `Under Review` needs no NDA, no contract and no approval, so the
     *     set of principals who can trigger this read is now every deal driver in the org.
     *
     * ═══ 🔴 THE FAILURE THIS PREVENTS IS A **DUPLICATE**, NOT A SILENCE ═══
     * Every other `without sharing` read in this repo prevents a SILENT NO-OP: zero rows, nothing
     * happens, nothing logs. This one is the shape ARCHITECTURE.md §2 names explicitly —
     * *"whenever a SYSTEM_MODE automation read against a Private-OWD object is used to decide
     * WHETHER SOMETHING ALREADY EXISTS, sharing is not a robustness question, it is a correctness
     * one — a filtered read does not disable the feature, it inverts it."*
     *
     * Concretely: `SharePoint_Folder_ID__c` is the idempotency guard. Under `with sharing` a
     * principal who cannot see the Property row gets ZERO ROWS, the service reads that as "no
     * folder exists yet", and it creates a SECOND SharePoint folder for a property that already has
     * one. `conflictBehavior: rename` guarantees the duplicate SUCCEEDS rather than colliding, so
     * the org ends up with "Magnolia Crossing" and "Magnolia Crossing 1" holding two halves of one
     * deal's documents, with no error anywhere and the Salesforce URL pointing at whichever was
     * written last. The sweep would then repeat that every run. An external, unrecoverable write
     * driven by an under-read guard is strictly worse than a missing folder.
     *
     * ═══ WHAT THIS DOES NOT WIDEN ═══
     * Nothing read here reaches a user. `Name` becomes a folder name in a library the running
     * principal may not be able to open; the other three are written back to the same row by a
     * service with no return value. There is no read surface to leak through, and no UI consumes
     * this method.
     *
     * ═══ SCOPE — AS NARROW AS APEX ALLOWS ═══
     * Inner classes do NOT inherit the outer class's sharing, so this is declared explicitly and
     * `PropertySelector` itself STAYS `with sharing`. It is `private`, so the only way in is the
     * two public static wrappers above. It is deliberately SEPARATE from `AssetCreationReads`
     * rather than merged with it: that class's argument is about a missing PM tree root, this one's
     * is about a duplicate external write, and a shared class would let a third read inherit
     * whichever argument it happened to sit next to.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance methods and the
     * `new FolderCreationReads()` at each call site.
     */
    private without sharing class FolderCreationReads {

        /**
         * The deal-folder state of a set of properties, read without sharing. See
         * `selectFolderStateByIds` for the field set and the `SYSTEM_MODE` justification, and the
         * enclosing class for the sharing one.
         *
         * @param propertyIds The properties to read; never null/empty (the wrapper guards it).
         * @return The matching rows; empty when none of the Ids resolve.
         */
        private List<Property__c> folderStateByIds(Set<Id> propertyIds) {
            return [
                SELECT Id, Name, SharePoint_Folder_ID__c, SharePoint_Folder_URL__c,
                       SharePoint_Folder_Status__c
                FROM Property__c
                WHERE Id IN :propertyIds
                WITH SYSTEM_MODE
            ];
        }

        /**
         * The recovery queue, read without sharing. See `queryFolderSweep` for why both statuses
         * are in scope and why there is no age filter.
         *
         * The field set matches `folderStateByIds` so the batch could act on the locator rows
         * directly if it ever needed to; today it passes Ids to `DealFolderService`, which re-reads
         * them through the wrapper above so the idempotency guard is evaluated in the same
         * transaction as the callouts.
         *
         * @return A locator over every owed row in the org, oldest first.
         */
        private Database.QueryLocator folderSweepLocator() {
            Set<String> workQueue = new Set<String>{
                DealFolderService.STATUS_PENDING,
                DealFolderService.STATUS_FAILED
            };
            return Database.getQueryLocator([
                SELECT Id, Name, SharePoint_Folder_ID__c, SharePoint_Folder_URL__c,
                       SharePoint_Folder_Status__c
                FROM Property__c
                WHERE SharePoint_Folder_Status__c IN :workQueue
                WITH SYSTEM_MODE
                ORDER BY CreatedDate ASC
            ]);
        }
    }

    /**
     * 🔴 THE WS3 PROPERTY-REUSE LOOKUP, WHICH MUST RUN **WITHOUT SHARING** (2026-08-30).
     *
     * ═══ WHY — `WITH SYSTEM_MODE` IS NOT ENOUGH, AND THE TWO HALVES ARE SEPARATE QUESTIONS ═══
     * `SYSTEM_MODE` lifts FLS and CRUD only; it does NOT lift record sharing. The mode half is
     * argued at `selectByNormalizedAddresses` (a brand-new field, no FLS for anyone, `USER_MODE`
     * throws rather than degrades, and the throw rolls back the conversion). This is the sharing
     * half. Measured against this repo, unchanged since the two classes above were written:
     *   - `objects/Property__c/Property__c.object-meta.xml` -> `sharingModel = Private`.
     *   - `sharingRules/Property__c.sharingRules-meta.xml` holds ONE rule, an OWNER rule sharing
     *     rows owned by the `Acquisition` QUEUE to `DPEG_Acquisitions_Team`. 🔴 THE ROWS THIS READ
     *     LOOKS FOR ARE PRECISELY THE ONES THAT RULE CANNOT REACH: a Property created by
     *     `LeadConvertService` is owned by whoever converted the FIRST Lead, never by the queue.
     *   - `viewAllRecords = true` on `Property__c` comes from exactly four permission sets:
     *     `DPEG_Acquisitions`, `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`,
     *     `DPEG_Property_View`. A user can convert a Lead while holding none of them.
     *
     * ═══ 🔴 THE FAILURE THIS PREVENTS IS A **DUPLICATE**, NOT A SILENCE ═══
     * This is the shape ARCHITECTURE.md §2 names explicitly: a `SYSTEM_MODE` automation read
     * against a Private-OWD object used to decide WHETHER SOMETHING ALREADY EXISTS. *"A
     * sharing-filtered read does not disable the feature, it inverts it into a duplicate-maker."*
     * Concretely: broker A's deal creates "1400 Royal Lane"; broker B emails the same building to a
     * different analyst; under `with sharing` that analyst's conversion sees ZERO ROWS, concludes
     * the building is new, and creates a second `Property__c` — i.e. WS3 would deploy green and do
     * nothing at all for exactly the population it was built for, since two brokers competing on
     * one building is the scenario, not the edge case.
     *
     * ═══ WHAT THIS DOES NOT WIDEN ═══
     * The query returns an Id and a machine-generated key, and BOTH are consumed inside
     * `LeadConvertService`; neither is returned to a caller, rendered, or logged. What the running
     * user gains is a LOOKUP VALUE on their own Opportunity, and the record behind it stays as
     * unreadable to them as it was before — they get "insufficient privileges" on the Property tab.
     * ⚠ THAT IS A REAL, NEW, USER-VISIBLE CONDITION and it is the accepted cost of the user's
     * "reuse and change nothing" decision, not an oversight: see `LeadConvertService.createProperties`
     * where it is stated in full, and the WS3 release note. The remedy is a permission-set grant
     * (`DPEG_Property_View`), never a widening of this read.
     *
     * ═══ SCOPE — AS NARROW AS APEX ALLOWS ═══
     * Inner classes do NOT inherit the outer class's sharing, so this is declared explicitly and
     * `PropertySelector` itself STAYS `with sharing`. It is `private`, so the only way in is the
     * public static wrapper above. It is deliberately SEPARATE from `FolderCreationReads` even
     * though both prevent a duplicate: that one prevents a duplicate SharePoint folder — an
     * external write nothing in Salesforce can undo — while this one prevents a duplicate
     * `Property__c` row, which an admin can merge. Merging the classes would let this weaker case
     * quietly borrow that stronger argument, which is the drift the separation exists to stop.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new ReuseLookupReads()` at the call site.
     */
    private without sharing class ReuseLookupReads {

        /**
         * The existing Properties for a set of normalized-address keys, read without sharing. See
         * `selectByNormalizedAddresses` for the field set, the ordering contract and the
         * `SYSTEM_MODE` justification, and the enclosing class for the sharing one.
         *
         * ⚠ CASE. `Normalized_Address__c` is `caseSensitive = false`, so `IN` matches case-blind at
         * the index. That is a backstop, not the mechanism — `normalizeAddress` lowercases before
         * it returns, so every key written and every key bound here is already lower-case. Do not
         * rely on the flag to reconcile a differently-cased key from some other producer; there is
         * no other producer, by design.
         *
         * @param normalizedAddresses The keys to look up; never null/empty/blank (the wrapper
         *                            guards and strips).
         * @return The matching rows, oldest first; empty when no key resolves.
         */
        private List<Property__c> byNormalizedAddresses(Set<String> normalizedAddresses) {
            return [
                SELECT Id, Normalized_Address__c
                FROM Property__c
                WHERE Normalized_Address__c IN :normalizedAddresses
                WITH SYSTEM_MODE
                ORDER BY CreatedDate ASC, Id ASC
            ];
        }
    }
}
