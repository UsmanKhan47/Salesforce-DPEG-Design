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
 *   - DealFolderService                      -> selectFolderStateByIds   (added 2026-08-11)
 *   - DealFolderSweepBatch.start             -> queryFolderSweep         (added 2026-08-11)
 *
 * ⚠ ALL THREE METHODS ARE `WITH SYSTEM_MODE` INSIDE A `private without sharing` INNER CLASS, AND
 * THE TWO INNER CLASSES ARE DELIBERATELY SEPARATE — `AssetCreationReads` and
 * `FolderCreationReads`. They could be merged and must not be: each carries its own argument for
 * why it escapes sharing, and one shared class would let a future read borrow whichever argument
 * happened to be written first. Read the method's Javadoc, never the class's.
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
     *   - `StageAdvanceService.NEXT_STAGE` maps `PSA ⇒ Closed Won` and
     *     `About to Close ⇒ Closed Won`, so any deal driver can drive it; and
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
     * the async job immediately before the callouts. The second read is not redundant: it is the
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
     * the running user's behalf while the platform files a won deal's documents. All four
     * SharePoint fields are created in THIS SAME CHANGE, and a Metadata-API-deployed custom field
     * arrives with NO field permissions for ANY profile, **System Administrator included**.
     * `WITH USER_MODE` does not degrade, it THROWS (`System.QueryException: No such column ...`,
     * which is how the platform reports an FLS denial). On the synchronous path that throw escapes
     * an after-update trigger as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolls back the deal
     * close itself** — verbatim the `TaskSelector.selectByTransactionDealIds` production incident,
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
     * synchronously by the trigger before any callout, so it catches a job that DIED UNCATCHABLY or
     * never ran at all. `Failed` is written by `DealFolderFinalizer` or by the service's own error
     * branch, so it catches the case this feature must survive: a deal closed by the TRANSACTIONS
     * persona, whose Queueable runs as a user holding no External Credential Principal Access, so
     * every callout is refused. Those deals MUST reach a sweep running as a granted principal.
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
     *     to Closed Won — including one who can see none of its Property rows.
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
}
