/**
 * Service for the Disposition (closing) write workflow.
 *
 * Owns the business logic behind DispositionController.findOrCreate (P6 controller
 * thinning): the idempotent "find the Property Asset's current Disposition, or create
 * one" operation. Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2, this
 * DML is Service work, not Controller work — the controller now only marshals input,
 * delegates here, and maps failures to an AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5).
 *
 * ── 🔴 TWO ENTRY POINTS SINCE 2026-08-19, AND THEY ARE NOT INTERCHANGEABLE ───
 * `findOrCreate(assetId)`                        — the ORIGINAL. Untouched by the flow redesign
 *                                                  and deliberately so: it has callers, it stamps
 *                                                  `On_Market` unconditionally, and it does not
 *                                                  submit anything.
 * `initiateAndSubmit(assetId, recordTypeName)`   — the NEW Sell-Meter Initiate path (design
 *                                                  decision 1 / DEV-1). The user picks the record
 *                                                  type in a modal, and the create is followed by
 *                                                  an automatic `Sale_Decision_Approval`
 *                                                  submission.
 *
 * ⚠ THEY SHARE THE IDEMPOTENT FIND AND THE RED-BAND GATE BY CALLING THE SAME HELPERS, NOT BY ONE
 * DELEGATING TO THE OTHER. `findOrCreate` returns a bare Id and cannot express "created but not
 * submitted"; `initiateAndSubmit` returns a three-field outcome precisely so the client can toast
 * that state AND STILL NAVIGATE. Folding either into the other would force one of those two
 * contracts onto a caller that cannot use it.
 *
 * All SOQL is delegated to DispositionSelector and PropertyAssetSelector — this service
 * holds no inline SOQL. It throws the raw platform DmlException on a save failure and the
 * raw SellMeterGateException on a refusal; the AuraHandledException boundary lives in the
 * controller, NOT here, so the service stays UI-agnostic (also callable from Flow / Apex /
 * a future caller).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * THE SERVER-SIDE SELL-METER GATE (design §5.1)
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Before this change the red-band block existed ONLY in lwc/sellMeterList
 * (`actionDisabled: meter === 'RED'`), so any caller invoking the @AuraEnabled method
 * directly could open a disposition on an asset the business had said was not ready to
 * sell. The band is now computed server-side from the same SellMeterService.bandForPeak
 * the dashboard uses, so client and server cannot disagree.
 *
 * 🔴 THE GATE APPLIES TO THE CREATE BRANCH ONLY, AND THAT IS LOAD-BEARING. If a
 * Disposition already exists this method returns its Id UNCHANGED, no band read, no
 * refusal. An asset's Peak_Sell_Date__c drifts with the market, so an already-open
 * disposition would become unreachable the moment its asset re-banded RED — breaking
 * navigation to a live deal for a reason nobody asked for. The gate answers "may this be
 * STARTED?", never "may this be OPENED?".
 *
 * 🔴 YELLOW IS PERMITTED, NOT REFUSED. The yellow band is what the dashboard's Override
 * button exists for (Gate 1 Q2 = confirm-then-create). Refusing YELLOW here would make
 * that button a server-side dead end for the second time in this module's life.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 NEITHER CREATE PATH ASSERTS `Disposition_Deal_Actions`, AND THAT ASYMMETRY IS DELIBERATE
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Every OTHER new write in this feature opens with
 * `DispositionActionPermissionService.assertDispositionActionAccess()` as its first statement
 * (`DispositionApprovalService.submitForApproval` / `.selectOffer`,
 * `BovSubmissionService.replaceSelectedBroker`). `findOrCreate` and `initiateAndSubmit` do not.
 * Code review raised that as a critical gap on 2026-08-19; it was investigated and KEPT, because
 * adding the assert would close the analyst's entry point rather than close a hole. The evidence,
 * so nobody has to re-derive it:
 *
 *   🔴 POINTS 1 AND 2 WERE OVERTURNED LATER THE SAME DAY AND ARE QUOTED, NOT DELETED, BECAUSE THE
 *      DECISION THEY SUPPORTED IS UNCHANGED WHILE ITS EVIDENCE IS NOT. The user retired
 *      `Disposition_Deal_Driver` on 2026-08-19 and moved `Disposition_Deal_Actions` onto
 *      `DPEG_Disposition_Edit`. What the two points used to say:
 *        *"1. `Disposition_Deal_Actions` is granted by ONE permission set, `Disposition_Deal_Driver`,
 *        and that set is a member of NO permission set group — it is assigned by hand, deal driver
 *        by deal driver. (Measured on usman-dpeg 2026-08-19: it currently has ZERO assignees.)
 *        2. The Sell Meter audience is strictly WIDER. `DPEG_Junior_Analyst_PSG` carries
 *        `DPEG_App_Disposition` (the app), `DPEG_Apex_Access` ... and `DPEG_Disposition_Edit`, and
 *        does NOT carry `Disposition_Deal_Driver`. Analysts are exactly the population this page is
 *        for."*
 *      Both are now FALSE IN THE OPPOSITE DIRECTION: the token IS in a permission set group
 *      (`DPEG_Junior_Analyst_PSG`, via `DPEG_Disposition_Edit`), so JUNIOR ANALYSTS NOW HOLD IT.
 *      For the analyst persona an assert here would be a NO-OP, not a lockout.
 *
 *   1'. THE DECISION SURVIVES ON A DIFFERENT PERSONA, AND IT IS A REAL ONE — MEASURED, NOT ASSUMED.
 *      `DPEG_Principal_PSG` carries `DPEG_Apex_Access`, `DPEG_App_Disposition` and
 *      `DPEG_Disposition_View` — the READ-ONLY disposition set, which does NOT carry the token.
 *      A Principal can therefore open the Sell Meter and would be NEWLY DENIED by an assert here.
 *      That persona is not incidental: the Principal is the approver `initiateAndSubmit` submits
 *      to, so an assert would refuse the Initiate button to exactly the person the record is being
 *      escalated to.
 *   2'. ⚠ THE MARGIN IS NARROWER THAN IT WAS, AND THAT IS WORTH RE-DECIDING DELIBERATELY RATHER
 *      THAN INHERITING. This used to rest on "the token has essentially no holders"; it now rests
 *      on one view-only persona. If `DPEG_Disposition_View` ever gains the token, or the Principal
 *      is meant to be refused the create, the assert becomes correct and should be added on BOTH
 *      create paths at once — not on one.
 *   3. The gate is enforced DECLARATIVELY where it belongs and NOT here: the NINE custom deal
 *      actions on `Disposition_Record_Page` (of TWELVE entries — `Edit`, `Clone` and `Delete` carry
 *      no visibility rule at all and are governed by object CRUD, not by this permission) are
 *      AND-ed with
 *      `{!$Permission.CustomPermission.Disposition_Deal_Actions}`. `Sell_Meter.flexipage` carries
 *      no visibility rule at all and `lwc/sellMeterList` calls no guard — by design, and its own
 *      comment says why it does not import `c/dealActionGuard`. An assert here would therefore
 *      surface as a raw denial toast on a button nothing hides, for the page's whole audience.
 *   4. THE APPROVAL GATES THE SALE, NOT THE RECORD — and that distinction is the point, not a
 *      hedge. The record is created at `Disposition Readiness` — the first stage, where nothing has
 *      been released and nothing has been committed — and `initiateAndSubmit` immediately submits
 *      it into `Sale_Decision_Approval`. An analyst can PROPOSE a sale; only the two named
 *      principals can let it ADVANCE, and every stage past Readiness is gated by (3).
 *      ⚠ WHAT THE APPROVAL DOES NOT COVER, SO NOBODY READS THIS AS FULL COMPENSATION: it does not
 *      authorize the CREATE itself (a row exists, and is visible in reports and list views, the
 *      moment the method returns), and it does not authorize NOTIFYING THE PRINCIPALS (submitting
 *      pushes an approval request at two named approvers, which is an unauthenticated-by-permission
 *      way to put work in someone's queue). Those two are real residual exposure, bounded by the
 *      fact that a Readiness-stage row commits nothing and can be deleted. See the residual
 *      paragraph below for the CRUD/FLS half of the same picture.
 *
 * ⚠ THE HONEST RESIDUAL, NAMED RATHER THAN HIDDEN. `insert d` / `Database.insert(d, true)` carry
 * no `AccessLevel`, so both create paths run in SYSTEM mode for CRUD and FLS. A user who holds
 * `DPEG_Apex_Access` (which grants `DispositionController`) but NOT `Disposition__c` create — the
 * Transaction and Property Management teams, today — could create a Disposition by calling the
 * @AuraEnabled method directly, even though the platform would refuse them the standard New
 * button. That residual is NOT introduced by `initiateAndSubmit`: `findOrCreate` has shipped with
 * the identical system-mode insert since the dashboard was built, and the two methods are
 * deliberately identical about the stamp. Closing it means switching BOTH inserts to
 * `AccessLevel.USER_MODE`, which is a one-line change per method but is a real behaviour change
 * (a USER_MODE insert THROWS on the first field the running user lacks edit FLS on, and FLS truth
 * is not in this repo — profiles/** is .forceignore'd). It is left for a decision that owns both
 * methods and can be acceptance-tested as each persona; it is not something to change silently on
 * one of them.
 *
 * RECORD TYPE (Gate 1 Q1 = (a)): `findOrCreate`'s create branch stamps On_Market EXPLICITLY. Both
 * disposition paths start identically at Disposition Readiness, so the type is not
 * knowable from the sell meter; an off-market deal is switched by changing the record type
 * early, while the record is still at Readiness. The alternative — leaving RecordTypeId
 * null and inheriting the running user's PROFILE DEFAULT — was rejected because
 * `profiles/**` is .forceignore'd, making that behaviour org state this repo can neither
 * set nor verify. The stamp is guarded on isAvailable() so a user without the record type
 * (or an org where §4 has not deployed yet) falls back to the platform default rather than
 * throwing: a missing record type must not block a disposition.
 *
 * ✅ THE SENTENCE "THE TYPE IS NOT KNOWABLE FROM THE SELL METER" IS STILL TRUE AND IS EXACTLY WHY
 * `initiateAndSubmit` EXISTS. The redesign does not make the meter smarter — it ASKS THE USER, in
 * the Initiate modal, and passes the answer here. So the two methods differ in where the record
 * type comes from (a constant vs. an allow-listed parameter) and in nothing else about the stamp:
 * the same `isAvailable()` guard, the same fallback, the same reason.
 *
 * GOVERNOR BUDGET: 1 SOQL on the existing-Disposition path; 2 SOQL / 1 DML on the create
 * path. The record-type lookup is a describe, not a query, so it costs nothing.
 *
 * BULK: findOrCreate is structurally single-record-per-transaction — no trigger, no loop,
 * one invocation per LWC click. See DispositionServiceTest's header for the
 * .claude/rules/bulk-test-rule.md exemption and its reasoning.
 *
 * @see force-app/main/default/classes/DispositionController.cls (thin caller)
 * @see force-app/main/default/classes/DispositionSelector.cls (Disposition SOQL)
 * @see force-app/main/default/classes/PropertyAssetSelector.cls (the asset read — peak sell date
 *      for the sell-meter gate, and nothing else since 2026-08-25)
 * @see force-app/main/default/classes/SellMeterService.cls (the shared band function)
 */
public with sharing class DispositionService {

    /**
     * A DESIGNED REFUSAL, not a platform failure — which is the whole reason it is a named
     * type rather than a bare Exception. DispositionController.findOrCreate catches this
     * FIRST and rethrows its message verbatim to the user; everything else falls through to
     * the generic write-failure catch beneath it. Without the distinction a deliberate,
     * permanent "this property is not ready to sell" would reach the user as "This change
     * could not be saved. Refresh the page and try again" — advice that can never work.
     *
     * Its message is therefore USER-SAFE BY CONSTRUCTION: it is authored here, contains no
     * platform text, no field API names and no exception detail, and is safe to surface
     * verbatim. Any future message added to this type must hold that property.
     */
    public class SellMeterGateException extends Exception {}

    /**
     * Raised when `initiateAndSubmit` is handed a record-type developer name that is not on the
     * two-value allow-list.
     *
     * 🔴 THIS IS A CALLER DEFECT, NOT A USER-ACTIONABLE REFUSAL, AND THAT IS WHY IT IS A SEPARATE
     * TYPE FROM SellMeterGateException RATHER THAN A SECOND MESSAGE ON IT. The only production
     * caller is `sellMeterInitiateModal`, whose radio group is mandatory and offers exactly these
     * two values — so reaching this exception means a hand-crafted call or a client bug, neither of
     * which a user can fix by reading a message. `DispositionController.initiateAndSubmit`
     * therefore MASKS it behind the generic write-failure wording (its two-catch shape surfaces
     * only SellMeterGateException verbatim), which is deliberate: a user told "choose On Market or
     * Off Market" when they already did would go looking for a control that is working correctly.
     *
     * ⚠ Its message is nevertheless authored and user-safe, so a future caller MAY surface it if
     * that caller has a user who can act on it. Nothing about the type prevents that; today's
     * controller simply has no such user.
     */
    public class InvalidRecordTypeException extends Exception {}

    /**
     * Developer name of the record type `findOrCreate` stamps. An ALIAS of the canonical constant
     * on `DispositionDomain`, not a literal (code review C-2, 2026-08-19) — this module now has
     * exactly one source for these two strings, so the create path and the approval paths cannot
     * drift apart on casing.
     */
    @TestVisible
    private static final String ON_MARKET_RECORD_TYPE = DispositionDomain.RT_ON_MARKET;

    /** The off-market twin. Only `initiateAndSubmit` can reach it — `findOrCreate` cannot. */
    @TestVisible
    private static final String OFF_MARKET_RECORD_TYPE = DispositionDomain.RT_OFF_MARKET;

    /**
     * The ALLOW-LIST, and the reason `initiateAndSubmit` takes a String at all rather than an enum.
     *
     * 🔴 THE PARAMETER CROSSES THE LWC BOUNDARY, SO IT IS ATTACKER-SUPPLIED BY DEFINITION. An
     * unchecked developer name reaches `getRecordTypeInfosByDeveloperName()`, which happily
     * resolves ANY record type on this object — today that is only these two, but the object gains
     * record types the way every object does, and an allow-list written now costs nothing and
     * cannot drift open. This is the same argument
     * `RecordStageAdvanceService.advanceTo`'s explicit-target allow-list makes for stage values:
     * derive where you can, allow-list where you cannot.
     *
     * ⚠ APEX Set&lt;String&gt; MEMBERSHIP IS CASE-SENSITIVE, and so is
     * `getRecordTypeInfosByDeveloperName()`'s own map. Both agree with the metadata casing in
     * objects/Disposition__c/recordTypes/, so 'on_market' is REFUSED here rather than silently
     * failing to resolve one layer down. That is the intended, louder failure.
     */
    private static final Set<String> ALLOWED_RECORD_TYPES = new Set<String>{
        ON_MARKET_RECORD_TYPE,
        OFF_MARKET_RECORD_TYPE
    };

    /**
     * The stage every disposition is created at, stamped EXPLICITLY.
     *
     * ⚠ IT HAPPENS TO EQUAL THE FIELD-LEVEL DEFAULT (`Disposition Readiness` carries
     * `<default>true</default>` on `Disposition_Stage__c`), and is set anyway for the same reason
     * `DispositionStageEntryService`'s initial-status constants are: "a new disposition starts at
     * Readiness" is a business decision of this feature — it is the entry criterion of
     * `Sale_Decision_Approval`, which the very next statement submits into — and an implicit
     * default is not falsifiable by a test.
     */
    @TestVisible
    private static final String READINESS_STAGE = 'Disposition Readiness';

    // The user-facing refusal for a RED asset. Plain ASCII on purpose (the repo's other
    // user-safe controller messages are too) and phrased as the business rule, not as an
    // error: the user has done nothing wrong, the property simply is not ready yet.
    @TestVisible
    private static final String RED_BAND_REFUSAL =
        'This property is not ready to sell - its peak sell date is more than 90 days away, '
        + 'so a disposition cannot be initiated yet.';

    // ── initiateAndSubmit's three outcome messages ───────────────────────────
    // All three are AUTHORED, plain-ASCII and user-safe by construction: no platform text, no
    // field API names, no exception detail. They travel to the client inside InitiateOutcome, NOT
    // as exceptions, because none of the three is a failure the client should treat as one — in
    // every case a Disposition exists and the client must navigate to it.

    @TestVisible
    private static final String INVALID_RECORD_TYPE_REFUSAL =
        'Choose On Market or Off Market to start a disposition.';

    @TestVisible
    private static final String SUBMITTED_MESSAGE =
        'Disposition created and submitted for the Sale Decision approval.';

    /**
     * 🔴 THE MESSAGE THIS WHOLE RETURN SHAPE EXISTS FOR. Before it, a submit failure after a
     * SUCCESSFUL insert had exactly two expressible outcomes and both were wrong: throw, and the
     * user is told nothing was created when a Disposition demonstrably was (they find it later,
     * unsubmitted, and re-Initiate — producing the second one); or swallow, and the user is told
     * it was submitted when no approver will ever see it. The third state is real and this names
     * it, WITH the recovery step.
     */
    @TestVisible
    private static final String CREATED_NOT_SUBMITTED_MESSAGE =
        'Disposition created, but it could not be submitted for approval automatically. '
        + 'Open the disposition and use Submit for Approval.';

    /**
     * Returned by the EXISTING-record branch. Not an error and not a warning — the button is
     * idempotent by design, and saying so is friendlier than silence.
     */
    @TestVisible
    private static final String ALREADY_EXISTS_MESSAGE =
        'This property already has a disposition. Opening it.';

    /**
     * Returns the most-recent Disposition for a Property Asset, creating one when none
     * exists yet — the find-or-create the Disposition dashboard button relies on so the
     * closing workspace self-seeds on first open. Idempotent: a second call for an asset
     * that already has a Disposition returns the existing Id and creates nothing.
     *
     * On the CREATE branch only, the asset's sell-meter band is checked and a RED asset is
     * refused (see the class header). YELLOW and GREEN both create.
     *
     * The created record carries the asset lookup and the On_Market record type, and nothing else.
     *
     * ⚠ IT BRIEFLY STAMPED AN EXPECTED VALUE ON 2026-08-25 AND NO LONGER DOES — DO NOT RE-ADD IT.
     * For a few hours that day this method copied the asset's `Target_Sale_Price__c` onto
     * `Asking_Price__c` ("Expected Value"). The user then retired `Asking_Price__c` from the
     * disposition flow entirely: `BOV_Score__c` and the Disposition-Readiness submission gate BOTH
     * read `Property_Asset__r.Target_Sale_Price__c` directly now, so a copy on the Disposition has
     * no consumer and would be a second, silently-diverging source of truth for the same number.
     * The field still exists (additive retirement) and would still compile here. That is not a
     * reason to write to it. `initiateAndSubmit` lost the identical stamp in the same change, so
     * the two create paths still differ only in where the record type comes from.
     *
     * @param assetId the Property_Asset__c to read/create the Disposition under
     * @return the existing or newly created Disposition__c Id
     * @throws DispositionService.SellMeterGateException when no Disposition exists yet and
     *         the asset's peak sell date bands RED (more than 90 days out, or absent)
     * @throws System.QueryException when the create branch is reached and assetId does not
     *         resolve to a Property_Asset__c
     * @throws System.DmlException on a platform save failure
     */
    public static Id findOrCreate(Id assetId) {
        Disposition__c existing = DispositionSelector.selectMostRecentByPropertyAssetId(assetId);
        if (existing != null) {
            // EXISTING-RECORD EARLY RETURN — deliberately ahead of the gate. See the class
            // header: the sell meter governs starting a disposition, never reopening one.
            return existing.Id;
        }

        Property_Asset__c asset = PropertyAssetSelector.selectPeakSellDateById(assetId);
        if (SellMeterService.BAND_RED == SellMeterService.bandForPeak(asset.Peak_Sell_Date__c)) {
            throw new SellMeterGateException(RED_BAND_REFUSAL);
        }

        Disposition__c d = new Disposition__c(Property_Asset__c = assetId);
        Id onMarketId = recordTypeIdFor(ON_MARKET_RECORD_TYPE);
        if (onMarketId != null) {
            d.RecordTypeId = onMarketId;
        }
        insert d;
        return d.Id;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // INITIATE + AUTO-SUBMIT — the Sell Meter modal path (2026-08-19, DEV-1)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * What `initiateAndSubmit` returns, and the reason it returns a shape rather than an Id.
     *
     * 🔴 THE THREE FIELDS ARE NOT A CONVENIENCE. `dispositionId` is ALWAYS populated on a
     * non-throwing return — including when `submitted` is false — because the client's job in
     * every non-throwing case is the same: NAVIGATE TO THE RECORD. `submitted` is what decides the
     * toast VARIANT (success vs. warning), and `message` is the authored text for it. A client that
     * reads only `dispositionId` still behaves correctly; one that reads only `submitted` and
     * treats false as a failure does not, which is why the client contract is written down here.
     *
     * ⚠ IT CARRIES @AuraEnabled AND THE SERVICE IS STILL UI-AGNOSTIC. The annotation makes the
     * shape serializable; it introduces no dependency on the controller, no `AuraHandledException`,
     * and nothing that stops Flow or Apex calling this method. Repo precedent for an @AuraEnabled
     * DTO declared in a service: `BrokerLeaderboardService.Row`,
     * `DispositionTractionService.Traction`. The rejected alternative — a parallel DTO in the
     * controller with a field-by-field copy — buys nothing and adds a shape that can be renamed on
     * one side only, which is the failure mode where the Apex compiles, the Jest passes, and the
     * wire silently delivers `undefined`.
     */
    public class InitiateOutcome {
        /** The existing or newly created Disposition. Never null on a non-throwing return. */
        @AuraEnabled public Id dispositionId;
        /** True only when an approval process actually accepted the submission. */
        @AuraEnabled public Boolean submitted;
        /** Authored, user-safe text for the toast. Never platform text. */
        @AuraEnabled public String message;
    }

    /**
     * Creates a Disposition for a Property Asset AT THE CALLER'S CHOSEN RECORD TYPE and submits it
     * into `Sale_Decision_Approval` in the same transaction — the Sell Meter "Initiate" modal's
     * server half (user-confirmed decision 1).
     *
     * ── THE FIVE STEPS, IN THIS ORDER, EACH FOR ITS OWN REASON ───────────────
     * 1. ALLOW-LIST the record type name. FIRST, before any query: an invalid name is a caller
     *    defect and must not cost a SOQL to discover.
     * 2. IDEMPOTENT FIND. An asset that already has a Disposition returns THAT Id with
     *    `submitted = false` and the "already exists" message.
     *    🔴 NO RECORD-TYPE CHANGE AND NO RE-SUBMIT ON THAT BRANCH, AND BOTH HALVES ARE
     *    LOAD-BEARING. Re-stamping the record type would let a second Initiate click silently
     *    convert a live off-market sale into an on-market one — a stage-set change on a record
     *    already walking a path — and re-submitting would either duplicate an approval or fail
     *    against a pending one. The button opens what exists; it never re-opens it.
     * 3. THE RED-BAND GATE, UNCHANGED, AND STILL ON THE CREATE BRANCH ONLY. See the class header:
     *    the meter governs STARTING a disposition, never reopening one. `findOrCreate` and this
     *    method must agree about that, and they do because both put the find ahead of the gate.
     * 4. CREATE at `Disposition Readiness` with the chosen type — AND WITH NO PRICE STAMP.
     *    ⚠ It seeded `Asking_Price__c` ("Expected Value") from the asset
     *    for a few hours on 2026-08-25; the user then retired that field from the disposition flow,
     *    and both consumers (`BOV_Score__c` and the Readiness submission gate) now read
     *    `Property_Asset__r.Target_Sale_Price__c` directly. See `findOrCreate` for why re-adding the
     *    stamp would create a second, diverging source of truth. One DML.
     * 5. SUBMIT. See `submitSaleDecision` for why a failure here returns rather than throws.
     *
     * ⚠ THERE IS NO `assertDispositionActionAccess()` AT THE TOP OF THIS METHOD AND THAT IS A
     * DECISION, NOT AN OMISSION — see the class header's "NEITHER CREATE PATH ASSERTS
     * `Disposition_Deal_Actions`" section for the four pieces of evidence and the named residual.
     * Adding one here closes the Sell Meter for every junior analyst; the control on this path is
     * the `Sale_Decision_Approval` submission on the very next line.
     *
     * ── GOVERNOR BUDGET ─────────────────────────────────────────────────────
     * Existing-disposition path: 1 SOQL, 0 DML. Create path: 2 SOQL + 1 DML + 1 SOQL for the
     * pending gate + the approval submission. The record-type lookup is a describe and costs
     * nothing.
     *
     * ── BULK ────────────────────────────────────────────────────────────────
     * Structurally single-record-per-transaction — no trigger, no loop, one invocation per modal
     * click — so the `.claude/rules/bulk-test-rule.md` 251-record mandate does not apply, exactly
     * as it does not apply to `findOrCreate`. Record that reasoning in the test class header so
     * review does not demand it.
     *
     * @param assetId the Property_Asset__c to create the Disposition under
     * @param recordTypeDeveloperName `On_Market` or `Off_Market`; case-sensitive
     * @return an outcome carrying the Disposition Id, whether it was submitted, and an authored
     *         message. Never null.
     * @throws DispositionService.InvalidRecordTypeException when the name is blank or off the
     *         allow-list (a caller defect — the controller masks it)
     * @throws DispositionService.SellMeterGateException when no Disposition exists yet and the
     *         asset's peak sell date bands RED
     * @throws System.QueryException when the create branch is reached and assetId does not resolve
     *         to a Property_Asset__c
     * @throws System.DmlException on a platform save failure
     * @example
     * DispositionService.InitiateOutcome outcome =
     *     DispositionService.initiateAndSubmit(assetId, 'Off_Market');
     */
    public static InitiateOutcome initiateAndSubmit(Id assetId, String recordTypeDeveloperName) {
        // STEP 1 — allow-list before anything costs a query. Return-early per .claude/rules.
        if (String.isBlank(recordTypeDeveloperName)
                || !ALLOWED_RECORD_TYPES.contains(recordTypeDeveloperName)) {
            throw new InvalidRecordTypeException(INVALID_RECORD_TYPE_REFUSAL);
        }

        // STEP 2 — the idempotent find, ahead of the gate. Same read findOrCreate uses.
        Disposition__c existing = DispositionSelector.selectMostRecentByPropertyAssetId(assetId);
        if (existing != null) {
            return outcome(existing.Id, false, ALREADY_EXISTS_MESSAGE);
        }

        // STEP 3 — the server-side sell-meter gate, create branch only. Verbatim from findOrCreate.
        Property_Asset__c asset = PropertyAssetSelector.selectPeakSellDateById(assetId);
        if (SellMeterService.BAND_RED == SellMeterService.bandForPeak(asset.Peak_Sell_Date__c)) {
            throw new SellMeterGateException(RED_BAND_REFUSAL);
        }

        // STEP 4 — create at Readiness with the CHOSEN type. NO price is stamped: see the method
        // doc above and `findOrCreate` — `Asking_Price__c` is retired from this flow and its two
        // former consumers read the asset's Target_Sale_Price__c directly.
        Disposition__c d = new Disposition__c(
            Property_Asset__c = assetId,
            Disposition_Stage__c = READINESS_STAGE
        );
        Id recordTypeId = recordTypeIdFor(recordTypeDeveloperName);
        if (recordTypeId != null) {
            d.RecordTypeId = recordTypeId;
        }
        // Database.insert with allOrNone = true (.claude/rules — "use Database methods"). A save
        // failure here MUST throw: there is no record to navigate to, so the caller has nothing to
        // do with a soft outcome. This is the one failure on this path that is not expressible as
        // an InitiateOutcome.
        Database.insert(d, true);

        // STEP 5 — submit, soft-failing.
        return submitSaleDecision(d.Id);
    }

    /**
     * Submits a freshly created Disposition into `Sale_Decision_Approval`, returning the outcome
     * instead of throwing.
     *
     * ── 🔴 WHY A FAILURE HERE RETURNS RATHER THAN THROWS. THIS IS THE WHOLE POINT OF DEV-1. ──
     * The insert has already succeeded and is NOT rolled back. Throwing would report "nothing was
     * created" about a record that exists — and the user's rational response to that is to click
     * Initiate again, at which point step 2's idempotent find returns the orphan they were told did
     * not exist. Every branch below therefore ends in an `InitiateOutcome` carrying the real Id.
     *
     * ⚠ AND IT MUST NOT SILENTLY SUCCEED EITHER. `submitted = false` plus the authored
     * created-but-not-submitted message is what makes the state visible AND recoverable: the
     * disposition sits at `Disposition Readiness`, where the `Submit_Sale_Decision` quick action is
     * visible, so the user's recovery is one click on a button that is already on the page. This is
     * the same "a refusal must be visible and recoverable, never silent" rule design decision D-1
     * applies to the auto-advance semaphore.
     *
     * ── THE PENDING GATE ────────────────────────────────────────────────────
     * ⚠ IT IS STRUCTURALLY UNREACHABLE FROM `initiateAndSubmit` TODAY AND IS KEPT ANYWAY — stated
     * so nobody deletes it as dead code. The Id was inserted three statements ago in this same
     * transaction, so no `ProcessInstance` can target it yet. It is kept because this is the single
     * submit path for this feature and the cost is one SOQL on a per-click singleton, whereas the
     * failure it prevents (a duplicate submission raising `ALREADY_IN_PROCESS`, which
     * `Approval.process` reports as a platform error) is exactly the kind that gets discovered in
     * production by a caller nobody predicted.
     *
     * ── `Approval.process(req, false)` — THE SECOND ARGUMENT IS LOAD-BEARING ─
     * `allOrNothing = false` makes the platform RETURN its errors in the `ProcessResult` rather
     * than throwing for the ordinary refusals (chiefly NO_APPLICABLE_PROCESS, which happens the
     * moment `Sale_Decision_Approval` is deactivated or its entry criteria drift off
     * `Disposition Readiness`). The try/catch is still required on top, because not every failure
     * mode is expressible as a result row, and both paths converge on the same soft outcome.
     *
     * ⚠ CATCHING HERE DOES NOT ROLL THE INSERT BACK. No savepoint is taken and none is wanted: the
     * created Disposition is the thing the user asked for and the thing we are handing back.
     *
     * @param dispositionId the just-created Disposition
     * @return a populated outcome; never null, never throwing
     */
    private static InitiateOutcome submitSaleDecision(Id dispositionId) {
        if (!ProcessInstanceSelector.selectPendingByTargetId(dispositionId).isEmpty()) {
            return outcome(dispositionId, false, CREATED_NOT_SUBMITTED_MESSAGE);
        }
        try {
            Approval.ProcessSubmitRequest request = new Approval.ProcessSubmitRequest();
            request.setObjectId(dispositionId);
            Approval.ProcessResult result = Approval.process(request, false);
            return result.isSuccess()
                ? outcome(dispositionId, true, SUBMITTED_MESSAGE)
                : outcome(dispositionId, false, CREATED_NOT_SUBMITTED_MESSAGE);
        } catch (Exception e) {
            // Admin-only detail. The user gets the authored message above; the reason the approval
            // would not accept the record belongs in the debug log, where it names the process.
            System.debug(LoggingLevel.ERROR, 'DispositionService.submitSaleDecision on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            return outcome(dispositionId, false, CREATED_NOT_SUBMITTED_MESSAGE);
        }
    }

    /** Builds the outcome. One constructor point, so a field can never be left unset by a branch. */
    private static InitiateOutcome outcome(Id dispositionId, Boolean submitted, String message) {
        InitiateOutcome result = new InitiateOutcome();
        result.dispositionId = dispositionId;
        result.submitted = submitted;
        result.message = message;
        return result;
    }

    /**
     * The record type Id for a developer name on `Disposition__c`, or null when it does not exist
     * in this org or is not available to the running user.
     *
     * Null is a legitimate answer, not an error: the caller then leaves RecordTypeId unset
     * and the platform applies its own default. This keeps a disposition creatable in an
     * org where the §4 record-type metadata has not deployed yet, and keeps a user who was
     * never granted the record type from being blocked by a stamp they did not ask for.
     *
     * A describe, not a query — it costs no SOQL.
     *
     * ⚠ IT WAS `onMarketRecordTypeId()` (no parameter) UNTIL 2026-08-19 AND WAS GENERALISED, NOT
     * REPLACED — `findOrCreate` passes the same constant it always did, so its behaviour is
     * byte-identical. There is deliberately NO allow-list guard inside this helper: `findOrCreate`
     * passes a private constant and `initiateAndSubmit` allow-lists FIRST, so a guard here would be
     * a third check on a value that has already been proven twice.
     *
     * ⚠ `getRecordTypeInfosByDeveloperName()` keys its map CASE-SENSITIVELY, so the two constants
     * must match objects/Disposition__c/recordTypes/ exactly. A mis-cased name resolves to null and
     * degrades to the platform default — silently, which is why the allow-list above is
     * case-sensitive too and refuses loudly one layer earlier.
     */
    private static Id recordTypeIdFor(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }
}
