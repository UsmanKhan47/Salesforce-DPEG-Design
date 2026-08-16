/**
 * Selector for NDA__c. Encapsulates ALL SOQL against NDA__c per ARCHITECTURE.md §2
 * and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumer: OpportunityDocStatusController
 * (the Deal Summary card's NDA row). NDA__c is a custom object — USER_MODE (P3
 * custom-field FLS gap = 0).
 *
 * ⚠ THE MODE IS A PROPERTY OF THE METHOD, NOT OF THIS CLASS — amended 2026-08-09 (Tranche 3A).
 * The A1-era claim "No SYSTEM_MODE / guest path" is now FALSE and has been removed rather than
 * left to mislead. `selectByDispositionIds` is `WITH SYSTEM_MODE` because it is an AUTOMATION
 * -PATH read behind the disposition NDA auto-create trigger; every other method here stays
 * `WITH USER_MODE` because each backs a read a human explicitly asked for. Read the method's own
 * Javadoc, which is where the justification lives (ARCHITECTURE.md §2). Same shape as
 * TaskSelector and InboundEmailStagingSelector.
 *
 * ⚠ AMENDED AGAIN 2026-08-16 (FSD Tranche 1, Item 2) — THE SENTENCE ABOVE NOW UNDERSTATES IT IN
 * BOTH HALVES, AND SHARING HAS JOINED MODE AS A PER-METHOD PROPERTY.
 *   MODE     this class has **SEVEN** public methods. **TWO** are `WITH SYSTEM_MODE` —
 *            `selectByDispositionIds` and `queryExpiryAlerts` — and the **FIVE** remaining ones
 *            stay `WITH USER_MODE`: `selectById`, `selectLatestByOpportunityId`,
 *            `selectLatestByDispositionId`, `selectByOpportunityIds` and
 *            `selectStageRequiredById`.
 *            ⚠ THE COUNT IS ENUMERATED RATHER THAN ASSERTED BECAUSE IT WAS WRONG HERE FIRST, AND
 *            THE WRONG NUMBER PROPAGATED. This block said "the FOUR remaining methods" when
 *            `queryExpiryAlerts` was added (2026-08-16), and ARCHITECTURE.md said the same in two
 *            places — one of them a 2026-08-09 sentence that was ALREADY wrong when written, since
 *            the class carried five `USER_MODE` methods then too. Corrected in all three places on
 *            2026-08-16 (code review W4). ARCHITECTURE.md §2 states that these class headers ARE
 *            the authoritative `SYSTEM_MODE` inventory, so a miscount here is not cosmetic: it is
 *            the number a future reviewer reconciles the doc against. Re-count against the method
 *            list, not against this sentence, whenever a method is added or removed.
 *            🔴 Do NOT read a future third SYSTEM_MODE method as conformant because two already
 *            exist — read its own header. The two present justifications are different arguments
 *            reaching the same answer.
 *   SHARING  🔴 THE CLASS-LEVEL `with sharing` KEYWORD IS NO LONGER THE WHOLE ANSWER.
 *            `queryExpiryAlerts` runs in a `private without sharing` inner class,
 *            `ExpiryAlertReads`, and that is the ONE method here that escapes sharing.
 *            `selectByDispositionIds` deliberately does NOT — its own header argues why, and the
 *            two must not be harmonised. Conflating mode and sharing is the D25 mistake this repo
 *            has already paid for once; each is argued at its own declaration.
 *
 * ⚠ NDA__c IS DUAL-PARENTED (Opportunity__c and Disposition__c), so this selector now
 * serves BOTH modules: selectLatestByOpportunityId for Acquisitions and
 * selectLatestByDispositionId for the Disposition BOV Outreach pill. They are separate
 * methods over separate lookups, not one parameterised query — the two parents are
 * different fields and a caller must not be able to pass the wrong one.
 *
 * NOT-FOUND CONTRACT — read-for-display: both consumer lookups (designated
 * Primary_NDA__c, else most-recent related NDA) treat "no NDA" as a normal state,
 * so both methods return SObject-or-null.
 *
 * DESIGN DEVIATION (noted in the A1 hand-off report): the P4 design §4 Skeleton C
 * proposed one dynamic `selectOneByClause(String tail, Id pid)` fed an allow-listed
 * WHERE fragment from the controller. That is replaced here by two static, named
 * methods. Rationale: (1) apex-layering-rule (non-negotiable) requires the selector
 * to own its full query text — passing a WHERE fragment from the controller is the
 * controller "writing its own query"; (2) it removes an avoidable dynamic-SOQL
 * string concatenation the analyzer flags as injection surface. Behavior
 * (primary-else-latest, null-on-empty) is preserved byte-for-byte.
 *
 * @see agent-output/p4-selector-design.md (§3 #8, §5)
 */
public with sharing class NdaSelector {

    /**
     * The NDA designated as an Opportunity's primary NDA (Primary_NDA__c lookup).
     *
     * @param ndaId NDA__c Id (the deal's Primary_NDA__c); null-safe.
     * @return The NDA with the Deal Summary field set, or null when the input is
     *         null or the row does not exist.
     */
    public static NDA__c selectById(Id ndaId) {
        if (ndaId == null) {
            return null;
        }
        List<NDA__c> rows = [
            SELECT Id, Name, Status__c, Date_Sent__c, NDA_Expiry_Date__c, NDA_Signed__c
            FROM NDA__c
            WHERE Id = :ndaId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created NDA related to an Opportunity — the fallback when
     * no primary NDA is designated.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return The latest related NDA (ORDER BY CreatedDate DESC LIMIT 1), or null
     *         when the input is null or the Opportunity has no NDA.
     */
    public static NDA__c selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<NDA__c> rows = [
            SELECT Id, Name, Status__c, Date_Sent__c, NDA_Expiry_Date__c, NDA_Signed__c
            FROM NDA__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created NDA related to a DISPOSITION — backs the NDA status pill
     * on the Disposition BOV Outreach tile (BovController.getOutreachSummary).
     *
     * READ-FOR-DISPLAY, null on miss: "no NDA yet" is a completely normal state for a
     * disposition (most never have one), which the caller renders as "No NDA". It must not
     * be an exception.
     *
     * ⚠ The field list is deliberately MINIMAL (Id + Status__c) — narrower than this
     * selector's Opportunity-side methods, on purpose. The pill renders Status__c and
     * nothing else, and under WITH USER_MODE every extra field is another way for this read
     * to throw for a persona that was granted NDA__c but not that particular field. The
     * caller wraps this call in a NARROW fail-soft try/catch for exactly that reason (Gate 1
     * Q7 — a QueryException reaching BovController's outer catch blanks the entire BOV
     * Outreach tile). ⚠ The grant and the catch are BOTH required; neither substitutes for
     * the other. Do not widen this field set without re-checking the FLS grants on
     * DPEG_Disposition_View and DPEG_Disposition_Edit.
     *
     * ⚠ Nothing about NDA__c itself changes with this method — no new values, no rename, no
     * Party_Role__c. The four-state model and the all-signed gate are a later change (D7).
     *
     * ⚠ ORDER BY carries an `Id DESC` TIE-BREAK, matching WireSelector.selectMostRecentByDispositionId.
     * CreatedDate is second-granular, so two NDAs created under one Disposition inside the same
     * second — routine in a test transaction and possible in a bulk load — leave `ORDER BY
     * CreatedDate DESC LIMIT 1` free to return either row. The pill would then be
     * non-deterministic. Do not drop the second sort key.
     *
     * @param dispositionId Parent Disposition__c Id; null-safe.
     * @return The latest related NDA with Id and Status__c populated (ORDER BY CreatedDate
     *         DESC, Id DESC LIMIT 1), or null when the input is null or the Disposition has
     *         no NDA.
     * @example
     * NDA__c nda = NdaSelector.selectLatestByDispositionId(dispositionId);
     * String status = (nda == null) ? null : nda.Status__c;
     */
    public static NDA__c selectLatestByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return null;
        }
        List<NDA__c> rows = [
            SELECT Id, Status__c
            FROM NDA__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * NDAs related to a set of Opportunities — backs OpportunityReviewService.ensureNda
     * idempotency (drop any deal that already has an NDA so a second is never opened).
     * Added by Module A2: the A2 OpportunityReviewService repoint needs a bulk,
     * set-based existence read that A1's single-record methods do not provide.
     * Bulk-safe (one query for the whole set).
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return NDAs with Id and Opportunity__c populated; empty when the input is
     *         null or empty.
     */
    public static List<NDA__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<NDA__c>();
        }
        return [
            SELECT Id, Opportunity__c
            FROM NDA__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * NDAs related to a set of DISPOSITIONS — backs DispositionStageEntryService's idempotency
     * ("never a second buyer NDA on one disposition", D19.1). Bulk-safe: one query for the whole
     * set, called once per trigger chunk.
     *
     * 🔴 `WITH SYSTEM_MODE`, AND IT IS THE ONLY MODE THAT IS CORRECT HERE. This is an
     * AUTOMATION-PATH read (ARCHITECTURE.md §2, "the automation-path exception"): the running
     * user asked to move a disposition to the NDA stage, not to read NDAs. Under `WITH USER_MODE`
     * a principal lacking FLS on ANY selected field — and `Party_Role__c` is brand new in this
     * tranche, so a Metadata-API-deployed field arrives with NO field permissions for ANY
     * profile, System Administrator included — makes the query THROW rather than degrade. That
     * throw happens inside an AFTER-UPDATE trigger, so it does not merely disable auto-create:
     * it ROLLS BACK THE USER'S OWN STAGE CHANGE with
     * CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY. That is precisely the reproduced production failure
     * ARCHITECTURE.md records for TaskSelector.selectByTransactionDealIds, one module later.
     *
     * ⚠ SYSTEM_MODE lifts CRUD/FLS ONLY — it does NOT lift sharing, and that is deliberate here
     * rather than an oversight. The class stays `with sharing`: every disposition in the set was
     * just edited by the running user, so they can already see it, and the NDAs hanging off it
     * are theirs to see too. This is NOT the shape that needed a `private without sharing` inner
     * class (contrast InboundEmailStagingSelector.RoutingReads, whose rows are owned by a
     * DIFFERENT principal than the one running the automation).
     *
     * ⚠ The field list is a CONTRACT. `Party_Role__c` IS the idempotency key and `RecordTypeId`
     * is what lets the caller tell an auto-created buyer NDA from a hand-added broker one.
     * Narrowing either does not fail loudly — it makes auto-create fire a second time on a
     * disposition that already has its NDA.
     *
     * @param dispositionIds Parent Disposition__c Ids; null/empty-safe.
     * @return NDAs with Id, Disposition__c, Party_Role__c, Status__c and RecordTypeId populated;
     *         empty when the input is null or empty.
     */
    public static List<NDA__c> selectByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<NDA__c>();
        }
        return [
            SELECT Id, Disposition__c, Party_Role__c, Status__c, RecordTypeId
            FROM NDA__c
            WHERE Disposition__c IN :dispositionIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * Loads an NDA for the generic stage-advance quick action — backs
     * RecordStageAdvanceService.advance.
     *
     * FETCH-FOR-USE: the caller reads the stage, derives the next one and writes it back, so a miss
     * is an error, not a normal state. A single-row SOQL assignment throws native
     * System.QueryException, matching OpportunitySelector.selectStageRequiredById.
     *
     * ⚠ NDA__c's stage field is `Status__c`, NOT `Stage__c` — it is one of only two of the six
     * stage-controlled deal children shaped that way (the other is
     * `Contract_Review__c.Negotiation_Status__c`), which is why RecordStageAdvanceService carries
     * the field name per object.
     *
     * 🔴 `RecordTypeId` IS SELECTED AND IS MANDATORY — added 2026-08-09 (Tranche 3A, D7 / D14.1).
     * `NDA__c` now carries `Acquisition_NDA` and `Disposition_NDA`, whose stage sequences DIVERGE
     * on a SHARED value: from `Sent` an acquisition NDA advances to `Received` and a disposition NDA
     * advances to `Signed`. RecordStageAdvanceService therefore cannot pick the right sequence from
     * `Status__c` alone. Dropping this field does not fail loudly — it silently routes every NDA to
     * the acquisition sequence, so treat the field list as a CONTRACT and do not narrow it.
     *
     * ⚠ This is the one widening that costs nothing under `WITH USER_MODE`. `RecordTypeId` is a
     * standard system field on which field-level security cannot be configured, so — unlike a custom
     * field — adding it creates no new FLS denial surface for a persona already able to read
     * `NDA__c`. The "deliberately minimal field list" philosophy in this class's other methods is
     * about FLS exposure, and this addition does not move it.
     *
     * ⚠ COMPILE ORDERING. A custom object with zero record types has NO `RecordTypeId` field at
     * all, so this query does not compile until `objects/NDA__c/recordTypes/` is deployed. Measured
     * on `usman-dpeg` 2026-08-09: `NDA__c` describes with only `Master` and no `RecordTypeId`.
     * Metadata (design §6 T1) must land before this class — the ordering is a COMPILE requirement
     * here, not merely a runtime one.
     *
     * Beyond that the field list stays MINIMAL (Id + the stage field + the record type) per this
     * selector's per-caller philosophy: the advance write touches nothing else.
     *
     * @param ndaId NDA__c Id; must reference an existing row.
     * @return The NDA with Id, Status__c and RecordTypeId populated.
     * @throws System.QueryException when no NDA matches the Id.
     */
    public static NDA__c selectStageRequiredById(Id ndaId) {
        return [
            SELECT Id, Status__c, RecordTypeId
            FROM NDA__c
            WHERE Id = :ndaId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * `NDA__c.Status__c` value the expiry-reminder ladder is scoped to. Gate 1 decision Q2.1
     * (a): SIGNED NDAs only.
     *
     * ⚠ IT MATCHES THE DEPLOYED `Acquisitions/NDAs_Expiring_This_Month` REPORT, WHICH IS WHY IT IS
     * `'Signed'` AND NOT SOMETHING ARGUED FROM FIRST PRINCIPLES. That report — the only existing
     * expiry-tracking surface in this repo — filters `Status__c equals Signed` AND
     * `Is_Non_Expiring__c = 0`. Matching it exactly is what stops the report and the reminder
     * disagreeing on day one about which NDAs are expiring. Changing this constant without
     * changing that report re-opens exactly that divergence.
     */
    @TestVisible
    private static final String STATUS_SIGNED = 'Signed';

    /**
     * 🔴 HOW WIDE THE LOCATOR REACHES — `TODAY + 5`, the WIDEST rung of `NdaExpiryService`'s ladder.
     *
     * ⚠ IT IS DUPLICATED KNOWLEDGE, AND THIS IS THE ONE PLACE THAT IS ALLOWED. A
     * `Database.QueryLocator` cannot bind an Apex collection, so `NdaExpiryService.ALERT_INTERVALS`
     * cannot be read here; and a selector calling a service would invert the layering
     * (`.claude/rules/apex-layering-rule.md`). The same trade, for the same reason, as
     * `OpportunitySelector.queryCallForOffersAlerts`'s `+ 7`.
     *
     * 🔴 IT IS A **CEILING**, NOT A THRESHOLD. Widening it merely costs rows the in-memory ladder
     * then skips; narrowing it below the widest rung is the ONLY way to break the feature — every
     * NDA outside it becomes invisible to the job and is silently never reminded about. **Whoever
     * adds a rung above 5 to `NdaExpiryService` must widen this too.**
     */
    @TestVisible
    private static final Integer ALERT_CEILING_DAYS = 5;

    /**
     * THE REMINDER JOB'S WORK QUEUE — every signed, expiring ACQUISITION NDA close enough to be
     * inside the reminder ladder. Backs `NdaExpiryAlertBatch.start` (FSD Tranche 1, Item 2).
     *
     * ═══ 🔴 THE DISCRIMINATOR IS `Opportunity__c != NULL`, DELIBERATELY **NOT** THE RECORD TYPE ═══
     * The requirement is "acquisition NDAs". The obvious mechanism —
     * `RecordType.DeveloperName = 'Acquisition_NDA'` — would **SHIP THIS FEATURE INERT**, and
     * silently: until post-deploy gate T-A1 / T-B every live `NDA__c` row still sits on **Master**
     * (which is exactly why `RecordStageAdvanceService` carries a null/Master fallback). A
     * record-type filter therefore returns ZERO ROWS for every un-migrated acquisition NDA, the job
     * runs daily, `finish()` logs an all-zeros summary, and the feature looks completely healthy
     * from every angle a deploy log or a test run can see.
     *
     * The parent lookup is the discriminator `Contract_Review__c.Disposition__c`'s own field
     * metadata mandates ("this lookup, NOT the record type, is the discriminator anything outside
     * the record page should test"), and it is the one `ContractExecutionService.handleExecution`
     * uses, for its stated reason 2: *"It WORKS DURING THE MIGRATION WINDOW."* A disposition NDA
     * carries `Disposition__c` with a null `Opportunity__c`, so the split is exact and survives the
     * migration in both directions.
     *
     * ═══ ▸ MODE = `WITH SYSTEM_MODE`, on AUTOMATION-PATH grounds (ARCHITECTURE.md §2) ═══
     * No principal ever asks for this read; a scheduler performs it on the Acquisition team's
     * behalf. And the argument here is unusually concrete rather than generic: this query selects
     * `NDA_Alert_Last_Interval__c` and `NDA_Alert_Expiry_Date__c`, **both created in this same
     * tranche**. A Metadata-API-deployed custom field arrives with NO field permissions for ANY
     * profile, System Administrator included — so under `USER_MODE` this locator would THROW for
     * the very administrator who deployed it, on day one, and the whole reminder feature would be
     * dead while everything looked shipped. `USER_MODE` throws; it does not degrade.
     *
     * ═══ 🔴 ▸ SHARING = `without sharing`, VIA `ExpiryAlertReads` — AND THIS IS THE ONE PLACE THE
     *         CALL-FOR-OFFERS PRECEDENT MUST **NOT** BE COPIED VERBATIM ═══
     * `OpportunitySelector.queryCallForOffersAlerts` is `WITH SYSTEM_MODE` on a `with sharing`
     * class, and its header argues `with sharing` is SUFFICIENT **because `Opportunity` internal
     * OWD is `ReadWrite` (measured)**. 🔴 THAT JUSTIFICATION DOES NOT TRANSFER, and copying the
     * keyword without the argument is the trap:
     *   - `objects/NDA__c/NDA__c.object-meta.xml` -> `sharingModel = Private`.
     *   - `sharingRules/NDA__c.sharingRules-meta.xml` holds exactly TWO rules
     *     (`NDA_Disposition_Team_RW`, `NDA_Disposition_Principals_R`) and BOTH are criteria-scoped
     *     to `RecordTypeId = 'Disposition NDA'`. **There is NO sharing rule covering acquisition
     *     NDAs at all** — they are reachable only via `viewAllRecords = true` on an acquisitions
     *     permission set.
     * So under `with sharing` a scheduling principal without an acquisitions permission set sees
     * only the NDAs they personally own. The locator returns zero rows, `finish()` logs all-zeros,
     * and that is **INDISTINGUISHABLE FROM "no NDA is expiring"** — the 2026-08-08
     * `InboundEmailStagingSelector.RoutingReads` incident, one module later. `SYSTEM_MODE` cannot
     * help: it lifts CRUD and FLS and **NEVER** sharing.
     *
     * ⚠ AND THE READ FIX IS ONLY HALF OF IT. The batch's marker WRITE has the identical exposure —
     * a Private-OWD `update` by a non-owner is REFUSED — and it is fixed separately, in
     * `NdaExpiryAlertBatch.MarkerWrites`. Neither covers the other.
     *
     * ═══ THE CEILING IS A REAL FILTER; THERE IS DELIBERATELY NO FLOOR ═══
     * `NDA_Expiry_Date__c <= TODAY + 5` is exactly the widest rung of the ladder, so an NDA 30 days
     * out is never even read. There is NO lower bound: a long-expired NDA stays in this locator
     * forever and is skipped IN MEMORY, because the marker makes it a no-op (once rung 2 is
     * stamped, the strictly-smaller test can never pass again). That costs one row per pass and
     * buys correctness for the case that actually matters — an NDA whose expiry passed before this
     * feature existed, or before it was signed, which has no marker and genuinely is owed its one
     * reminder. ⚠ Adding a floor would silence that NDA, so it is an ALERT-LOSS decision, not a
     * tuning knob: if the expired population ever grows enough to matter, take it THEN with the
     * population as evidence.
     *
     * ⚠ ORDER BY carries an `Id ASC` TIE-BREAK. `NDA_Expiry_Date__c` is a Date, so many rows share
     * one value and a bare single-key sort leaves chunk composition non-deterministic between
     * passes. It costs nothing and makes the ordering assertable.
     *
     * @return A locator over signed, expiring acquisition NDAs, soonest expiry first.
     * @example
     * public Database.QueryLocator start(Database.BatchableContext ctx) {
     *     return NdaSelector.queryExpiryAlerts();
     * }
     */
    public static Database.QueryLocator queryExpiryAlerts() {
        return new ExpiryAlertReads().expiryAlertLocator();
    }

    /**
     * 🔴 THE EXPIRY-REMINDER WORK QUEUE, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * It is its own class rather than a keyword on `NdaSelector` because `NdaSelector` backs FIVE
     * user-facing reads (the Deal Summary NDA row, the BOV Outreach pill, the auto-create
     * idempotency guard and the stage-advance load). A `without sharing` outer class would widen
     * every one of them silently. The escape is scoped to exactly one query, exactly as
     * `InboundEmailStagingSelector.RoutingReads`, `PropertyAssetSelector.AssetCreationReads` and
     * `PropertySelector.FolderCreationReads` are.
     *
     * The full argument — Private OWD, two sharing rules both scoped to the DISPOSITION record
     * type, and why a filtered read here is indistinguishable from a healthy job — is on
     * `queryExpiryAlerts`. Read it before changing this keyword.
     *
     * ⚠ RESIDUAL, STATED BECAUSE IT COULD NOT BE MEASURED FROM SOURCE: whether the platform
     * re-applies the BATCH CLASS's sharing context when it chunks a locator built here is not
     * established by any file in this repo. The three in-repo precedents above all build their
     * locator in a `without sharing` inner class while leaving the batch/caller `with sharing`, so
     * none of them answers it either.
     *
     * ✅ THE REMEDY WAS TAKEN UP FRONT ON 2026-08-16 (code review W2) RATHER THAN LEFT AS A WATCH.
     * ⚠ This paragraph used to end "If it does not, the remedy is `without sharing` on
     * `NdaExpiryAlertBatch` with its own written justification" — that is now DONE, not pending.
     * `NdaExpiryAlertBatch` is `without sharing`, argued in its own class header §4b, and the
     * argument is that it costs nothing: that class holds ZERO SOQL and ZERO direct DML (its one
     * `Database.update` lives in its own `without sharing` inner class) and every callee declares
     * its own sharing keyword, so the keyword widens nothing while closing the only path by which
     * the escape here could be silently re-applied.
     *
     * 🔴 THAT DID NOT CLOSE GATE G2 AND IS NOT A SUBSTITUTE FOR IT. Nothing above is a measurement.
     * G2 still stands: confirm AS THE SCHEDULING PRINCIPAL that a real pass selects — and stamps —
     * an acquisition NDA that principal does not own.
     *
     * ⚠ AND IT IS STILL NOT A LICENCE TO WIDEN **THIS** SELECTOR. `NdaSelector` backs five
     * user-facing reads; the escape stays scoped to this one query whatever the batch class says.
     */
    private without sharing class ExpiryAlertReads {

        /**
         * Signed, expiring acquisition NDAs inside the ladder, read without sharing.
         *
         * @return The locator; soonest expiry first, `Id ASC` as the tie-break.
         */
        private Database.QueryLocator expiryAlertLocator() {
            Date ceiling = Date.today().addDays(ALERT_CEILING_DAYS);
            String signedStatus = STATUS_SIGNED;
            return Database.getQueryLocator([
                SELECT Id, Name, Opportunity__c, Counterparty_Name__c, Status__c,
                       NDA_Expiry_Date__c, NDA_Alert_Last_Interval__c, NDA_Alert_Expiry_Date__c
                FROM NDA__c
                WHERE NDA_Expiry_Date__c != NULL
                  AND NDA_Expiry_Date__c <= :ceiling
                  AND Is_Non_Expiring__c = FALSE
                  AND Opportunity__c != NULL
                  AND Status__c = :signedStatus
                WITH SYSTEM_MODE
                ORDER BY NDA_Expiry_Date__c ASC, Id ASC
            ]);
        }
    }
}
