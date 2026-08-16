/**
 * RecordStageAdvanceService — ONE generic stage-advance service for the SEVEN acquisitions /
 * disposition / transaction CHILD objects whose stage is driven by a button rather than by the
 * Path:
 *
 *   NDA__c                              (Status__c)  PER RECORD TYPE — see below
 *   LOI__c                              (Stage__c)   PER RECORD TYPE — see below
 *   Contract_Review__c        (Negotiation_Status__c) PER RECORD TYPE — see below. ⚠ This line
 *                                                    used to read "the two types share ONE SEQUENCE
 *                                                    and differ ONLY in the GATE". FALSE since
 *                                                    2026-08-14 (observation 7): they now differ in
 *                                                    BOTH, and the shared map object is gone
 *   Underwriting__c                     (Stage__c)   Requested -> In Progress -> [approval] -> Approved -> Completed
 *   Construction_Feasibility_Review__c  (Stage__c)   Requested -> Site Visit -> Condition Assessment
 *                                                    -> Cost Estimate -> Share Opinion -> Completed
 *   Development_Feasibility_Review__c   (Stage__c)   Requested -> Feasibility analysis
 *                                                    -> Vendor proposals -> Share Opinion -> Completed
 *   Transaction__c                      (Stage__c)   Open Contract -> Due Diligence -> Closing Prep
 *                                                    -> Post-Closing -> Closed Won
 *                                                    ADDED 2026-08-12. The FIRST object here from
 *                                                    the TRANSACTIONS module rather than
 *                                                    acquisitions/disposition. ⚠ This line used to
 *                                                    add "and the first whose gate is
 *                                                    MEMBERSHIP-ONLY"; that was true for part of one
 *                                                    day. All three gates are now a single custom
 *                                                    permission — see StageActionGate.
 *
 * It exists so the Path's "Mark Status as Complete" button can be removed from these record pages
 * and every stage change routed through Apex, where the transition is derived (never supplied),
 * the permission is asserted server-side, and any future validation rule's message is surfaced to
 * the user instead of being swallowed.
 *
 * ── 🔴 THE MAPS ARE PER RECORD TYPE, NOT PER OBJECT (Tranche 3A, 2026-08-09) ──
 * THREE of the seven objects carry record types, and since 2026-08-14 ALL THREE have DIFFERENT
 * stage sequences per type (D7 / D14.1 / D6, plus observation 7):
 *
 *   NDA__c
 *   Acquisition_NDA   Pending  -> Sent -> Received -> Signed        explicit targets: none
 *                     gate: DEAL_DRIVER
 *   Disposition_NDA   Not Sent -> Sent -> Signed                    explicit targets: {Declined}
 *                     gate: DISPOSITION_DRIVER
 *
 *   LOI__c            (Tranche 3B, 2026-08-09 — this was the config addition the note at
 *                      CONFIG_BY_TYPE predicted, and it changed nothing below the config)
 *   Acquisition_LOI   Draft -> Under Review -> Submitted -> Negotiation -> Signed
 *                     explicit targets: {Negotiation, Signed}      gate: DEAL_DRIVER
 *                     ⚠ RENAMED THROUGHOUT 2026-08-14 (observation 5) from
 *                       Draft -> Prepare/Review -> Sent -> Counter -> Completed. Same SHAPE, new
 *                       labels; 'Draft' is the only surviving literal.
 *   Disposition_LOI   Received -> Under Review -> Countered by DPEG
 *                       -> Counter Received from Buyer -> Executed
 *                     explicit targets: {Countered by DPEG,       gate: DISPOSITION_DRIVER
 *                       Counter Received from Buyer} — the negotiation LOOP, added at the
 *                       Tranche 3B close-out (2026-08-09)
 *
 *   Contract_Review__c (Tranche 3C, 2026-08-09 for the GATE; observation 7, 2026-08-14 for the
 *                      SEQUENCE)
 *   Acquisition_PSA   Draft -> Negotiation -> Signed -> Executed
 *                     explicit targets: none                       gate: DEAL_DRIVER
 *   Disposition_PSA   Initial Draft -> Revised -> Ready for Execution -> Executed
 *                     explicit targets: none                       gate: DISPOSITION_DRIVER
 *
 * ── 🔴 Contract_Review__c IS SPLIT ON BOTH AXES — AND IT WAS SPLIT ON ONE AXIS FIRST ──
 * ⚠ THIS BLOCK USED TO BE TITLED "WHY Contract_Review__c IS SPLIT AT ALL WHEN ITS VALUES ARE
 * IDENTICAL" AND ARGUED THAT THE TWO TYPES SHARE ONE MAP OBJECT BY REFERENCE, BECAUSE "COPYING IT
 * WOULD INVITE THE TWO TO DRIFT APART WHILE THE REQUIREMENT IS THAT THEY CANNOT". That argument was
 * correct on 2026-08-09 and is OBSOLETE, not overturned — its premise (identical value sets) was
 * ended by observation 7. It is recorded here because the git history reads oddly without it and
 * because a future reader must not "restore" the shared reference as a tidy-up.
 *
 * The two axes, and why each is split, in the order they were split:
 *   - THE GATE (3C, 2026-08-09). A disposition persona holds `Disposition_Deal_Driver` and NOT
 *     `Acquisition_Deal_Driver`, and the two sets are disjoint (measured across every permission
 *     set in the repo: exactly one set carries each module's token). Left at a single
 *     DEAL_DRIVER config, `hasStageActionAccess` and `assertStageActionAccess` would REFUSE every
 *     disposition PSA for the only persona meant to work it — the sell-side PSA would be
 *     unadvanceable from its own record page.
 *     ⚠ AMENDED 2026-08-12: this used to say the disjointness was in FLS on
 *     `User.Disposition_Driver__c` vs `User.Deal_Driver__c`. Those flags are retired — the token is
 *     now the `Disposition_Deal_Actions` vs `Acquisition_Deal_Actions` CUSTOM PERMISSION. The
 *     disjointness, and therefore this whole argument, is unchanged; only what the sets carry is.
 *   - THE SEQUENCE (observation 7, 2026-08-14). The acquisition PSA moves to
 *     `Draft -> Negotiation -> Signed -> Executed`; the disposition PSA keeps its four values
 *     verbatim, and O3 of the requirements doc makes that a HARD STOP — those three values stay
 *     ACTIVE on the field precisely because Disposition_PSA still runs on them. A shared map would
 *     have to hold BOTH sides' values, and Apex DML does not enforce record-type picklist
 *     restriction, so `advance()` itself would then write an acquisition-only status onto a sale.
 *     Two maps is the only shape in which that is unexpressible.
 * ⇒ THE 3C LESSON STILL STANDS AND IS NOW JOINED BY ITS CONVERSE. Sharing a sequence is not
 *   sharing a gate (3C: someone who checks only the picklists ships a dead feature). And sharing
 *   an OBJECT is not sharing a sequence (observation 7: someone who edits one map and assumes the
 *   other followed ships a cross-module write). The two axes are independent in BOTH directions.
 *
 * ⚠ AND THE SPLIT COSTS ONE QUERY, WHICH IS NOT FREE AND IS WORTH KNOWING. `gateFor()`
 * short-circuits only for an object with ONE configured sequence, so Contract_Review__c now LOADS
 * the row inside `hasStageActionAccess` — a `cacheable=true` path invoked once per record view.
 * That is the same price NDA__c has paid since 3A and LOI__c since 3B, and it is accepted for the
 * same reason: the gate is a property of the record type and the record type is a property of the
 * row. Pinned by gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject.
 *
 * ── 🔴 THE GATE IS PER RECORD TYPE TOO, SINCE 2026-08-09 ─────────────────────
 * It used to live on StageConfig (per object) because all six objects then configured answered to
 * one persona.
 * That stopped being true the moment `NDA__c` served both modules: an acquisitions deal driver
 * must not be able to drive a SALE's NDA, nor a sale driver an acquisition's, merely because the
 * two share a table. The gate therefore moved onto StageTypeConfig alongside `nextStage` and
 * `explicitTargets` — all three are the per-record-type configuration, and keeping them in one
 * object is what stops a future change extending one and forgetting the others.
 *
 * The visible consequence is in hasStageActionAccess(), which now LOADS the row for a
 * multi-record-type object (see its own header for the two small behavioural changes that
 * follow). Objects with a single sequence short-circuit and still pay nothing.
 *
 * ⚠ ON NDA__c, 'Sent' and 'Signed' are SHARED by both value sets, so the CURRENT STAGE ALONE DOES
 * NOT IDENTIFY THE PATH. From 'Sent' an acquisition NDA advances to 'Received' and a disposition
 * NDA advances to 'Signed'. That single fact is why an object-keyed map cannot express this feature
 * and why the record type has to be read off the record.
 *
 * 🔴 ON LOI__c THE TWO STAGE SETS ARE NO LONGER DISJOINT — 'Under Review' IS SHARED BY BOTH SINCE
 * 2026-08-14 (observation 5). It is the acquisition sequence's second stage and the disposition
 * sequence's second stage. ⚠ THIS BLOCK USED TO OPEN "THE TWO STAGE SETS ARE FULLY DISJOINT, AND
 * THAT DOES NOT MAKE THE RECORD TYPE REDUNDANT HERE" and then gave three reasons the service needs
 * the record type ANYWAY. Every one of those three reasons still holds and is retained verbatim
 * below — but they have been promoted from "belt and braces" to "the only thing holding this
 * together", because the premise they were arguing against is now simply false.
 *
 * ⇒ NOTHING IN THIS CLASS REGRESSED, and that is a property of the 3A/3B design rather than luck:
 *   this service has always resolved the sequence from the RECORD TYPE and never from the stage
 *   value, so a shared stage cannot mis-route it. What DID break is everything OUTSIDE this class
 *   that keyed on the stage value alone — the LOI record-type files' own comments, the
 *   LOI_Record_Page visibility rules, and LOI__c.Is_Advance_Allowed__c, a formula whose header
 *   records that it omits a record-type test PRECISELY because the sets were disjoint (design
 *   collision C1). Those are the declarative half of this pack and are not fixed from here.
 *
 * The three reasons, unchanged, any one of which is sufficient:
 *   1. the PERMISSION GATE is not a function of the current stage at all — hasStageActionAccess is
 *      asked before any stage is known to the client, and answering it needs the record type;
 *   2. the EXPLICIT-TARGET allow-list is checked against a caller-supplied string, so deriving the
 *      allow-list from the record's current stage would let a row parked on a shared/unknown stage
 *      inherit the wrong list;
 *   3. Apex DML does not enforce record-type picklist restriction, so a row CAN carry an off-set
 *      stage — at which point "the sets are disjoint" is an assumption about data, not a fact.
 * ✅ AND THE SENTENCE THAT USED TO CLOSE THIS BLOCK WAS A PREDICTION THAT CAME TRUE: "Deriving the
 * sequence from the stage value would also silently break the day any LOI stage is shared, with no
 * compile error and no failing walk test." That day was 2026-08-14. Because the sequence is derived
 * from the record type, nothing broke.
 *
 * 🔴 THE EXPLICIT-TARGET ALLOW-LIST IS PER RECORD TYPE TOO, AND THAT IS THE SECURITY HALF OF THIS
 * CHANGE — NOT A TIDY-UP. Record-type picklist restrictions are enforced by the UI ONLY; Apex DML
 * does not enforce them. So an object-level allow-list containing 'Declined' (for the disposition
 * NDA's Mark Declined action) would let a hand-crafted advanceTo(acquisitionNdaId, 'Declined')
 * write a disposition-only value onto an acquisition NDA — the exact hole the allow-list exists to
 * close, re-opened one layer up. Making only nextStage record-type-aware LOOKS finished and is not.
 * Pinned by RecordStageAdvanceServiceTest.acquisitionNdaRefusesTheDispositionOnlyDeclinedTarget.
 *
 * ⚠ THE SAME HOLE EXISTS IN BOTH DIRECTIONS ON LOI__c, WHICH IS WHY THE 3B CONFIG SPLITS
 * LOI_EXPLICIT_TARGETS RATHER THAN SHARING IT. Held at object level, {Negotiation, Signed} would be
 * writable onto a DISPOSITION LOI — a value set that record type does not carry at all — and the
 * disposition type's own {Countered by DPEG, Counter Received from Buyer} would be writable onto an
 * ACQUISITION LOI, which carries neither. ⚠ The acquisition pair was {Counter, Completed} until
 * observation 5 renamed it; the two ALLOW-LISTS remain fully disjoint even though the two SEQUENCES
 * no longer are (they share 'Under Review', which is on neither list, deliberately). Pinned in both
 * directions by
 * acquisitionLoiRefusesADispositionStageAsAnExplicitTarget /
 * dispositionLoiRefusesTheAcquisitionExplicitTargets.
 *
 * 🔴 THAT SECOND DIRECTION STOPPED BEING HYPOTHETICAL AT THE 3B CLOSE-OUT. Until the loop actions
 * landed, Disposition_LOI supplied NO explicit targets, so the acquisition-side test could only
 * prove "the acquisition list has not silently widened to the union". It now has two real
 * disposition-only values to leak, and both are refused — which is the shape the test was written
 * in advance for.
 *
 * ── ⚠ THE CALL ORDER CHANGED, AND advanceTo's CHANGE IS THE LOAD-BEARING ONE ──
 * configFor() resolves from Id.getSObjectType() alone, so it still runs FIRST — it is what proves
 * the object is stage-controlled before load() is asked to dispatch, and it supplies the stage FIELD
 * NAME. What moved is the choice of MAP: the record type is not knowable until the row is in hand,
 * so map selection now happens AFTER load().
 *
 *   advance()    load() already ran before the map was consulted. Order effectively unchanged.
 *   advanceTo()  🔴 THE ALLOW-LIST CHECK NOW HAPPENS AFTER THE LOAD, where it used to happen
 *                before it. It has to: the allow-list is a property of the record type, and the
 *                record type is a property of the row. One visible consequence — advanceTo against
 *                a NON-EXISTENT Id and a disallowed target now raises System.QueryException where
 *                it previously raised RecordStageAdvanceException. Both surface a fixed generic
 *                message at the controller, so no user-visible wording changes.
 *
 * ── THE null / Master FALLBACK IS LOAD-BEARING, NOT DEFENSIVE ────────────────
 * Between the record-type deploy (T1) and the row migration (GATE T-B) every existing NDA, LOI and
 * Contract Review sits on the Master record type, and today — before T1 — none of the three has a
 * RecordTypeId field at all. Each StageConfig therefore names a defaultTypeKey pointing at the
 * ACQUISITION map, which is what keeps live rows advancing through that window. An object with no
 * record types (FOUR of the seven, since Transaction__c joined 2026-08-12) keeps a single map and
 * never pays a describe: record-type awareness degrades to exactly today's behaviour.
 *
 * ✅ ON Contract_Review__c THE FALLBACK USED TO BE THE QUIETEST OF THE THREE, AND OBSERVATION 7
 * MADE IT THE LOUDEST. ⚠ This block used to read: "Because both PSA types share one sequence, a
 * Master-type row advances CORRECTLY through the fallback — the walk works, the toasts are right,
 * nothing looks wrong ... There is no loud symptom to lead anyone to gate T-B here." That is FALSE
 * as of 2026-08-14 and is rewritten rather than left standing.
 *
 * The two sequences now differ, and the P3 row migration is scoped BY RECORD TYPE, so a Master-type
 * row is NOT migrated and keeps whatever value it had:
 *   - a legacy / Master ACQUISITION row still on 'Initial Draft' finds no entry in the acquisition
 *     fallback map and is REFUSED on its first click, naming its own stale status. That refusal is
 *     the loud symptom this block used to complain was missing — it points straight at gate T-B.
 *   - a Master-type DISPOSITION row is worse off than before, not better: it takes the ACQUISITION
 *     sequence, which no longer describes it at all, so it is refused as well as being on the wrong
 *     gate. Before observation 7 it at least walked. Gate T-A1/T-B closes both cases; nothing in
 *     Apex can.
 * See CONFIG_BY_TYPE for why the default nevertheless STAYS Acquisition_PSA (a refusal beats the
 * wrong write the disposition default would produce).
 *
 * ⚠ The fallback is safe on LOI__c for the same reason it is safe on NDA__c and for no other:
 * every LOI in the org today is buy-side by construction, because the Disposition__c lookup and the
 * sell-side stages arrive in this same tranche. It is a MIGRATION-WINDOW guarantee, not a general
 * one — the day a Master-type row can legitimately be sell-side, this fallback starts applying
 * buy-side stages and the ACQUISITIONS gate to a sale.
 *
 * ⚠ A REAL, NAMED record type with no map is a different case and is REFUSED, not defaulted. A
 * silent fallback there would apply the acquisition sequence to a record the acquisition sequence
 * does not describe — and, because DML does not enforce record-type picklist restrictions, would
 * happily write an off-set value. Failing loudly is also what makes a typo in a map key falsifiable
 * (Apex Map<String,...> keys are case-SENSITIVE while getDeveloperName() returns the metadata
 * casing, so a mis-cased key would otherwise degrade in silence).
 *
 * ── ⚠ THERE ARE TWO STAGE SERVICES. KNOW WHICH ONE YOU ARE EDITING ────────────
 *   StageAdvanceService        — OPPORTUNITY only. Its advance() BRANCHES into an approval
 *                                submission, and its advanceTo() exists because Opportunity has
 *                                parallel record-type branches (Land / Retail) and an off-ramp;
 *                                that is why it carries ALLOWED_EXPLICIT_TARGETS.
 *   RecordStageAdvanceService  — THIS CLASS. The seven child objects above, carrying TEN
 *                                StageTypeConfigs since Transaction__c joined 2026-08-12 (NDA 2,
 *                                LOI 2, Contract Review 2, plus one each for the FOUR
 *                                record-type-free objects). THREE
 *                                of the ten are not straight lines, and each is a
 *                                DIFFERENT shape: the ACQUISITION LOI BRANCHES at 'Submitted', the
 *                                DISPOSITION NDA has the 'Declined' OFF-RAMP, and the DISPOSITION
 *                                LOI is a LOOP (Countered by DPEG <-> Counter Received from Buyer).
 *                                All three reach their extra stages through a per-record-type
 *                                allow-list rather than a free-form write. ⚠ Every exception is
 *                                RECORD-TYPE-scoped, never object-scoped — the ACQUISITION NDA and
 *                                BOTH PSA types are genuinely linear and offer no explicit target
 *                                at all.
 * They are deliberately NOT merged: folding a live, gated, deployed feature into a new one buys
 * tidiness and costs a re-test of the Opportunity approval hand-off. They DO share the permission
 * service (OpportunityActionPermissionService) and the confirm/guard shape on the client. Same
 * "know which one you are editing" convention as the three LeadConvert* classes.
 *
 * ── 🔴 THERE IS NO *GENERIC* advanceTo, AND THERE MUST NEVER BE ONE ──────────
 * A generic explicit-target write across seven objects would re-open exactly the hole
 * StageAdvanceService.ALLOWED_EXPLICIT_TARGETS was created to close: any holder of class access
 * could write any stage on any of seven objects, skipping every hop. advance() derives the target
 * from the map, so it CANNOT skip a hop. advanceTo() exists only for the three
 * branch / off-ramp / loop cases and writes NOTHING that is not on the allow-list FOR THAT RECORD
 * TYPE. Adding a branch action means adding its stage to that record type's set — never widening
 * the check.
 *
 * ── WHY THE MAPS ARE APEX AND NOT CUSTOM METADATA ────────────────────────────
 * A Stage_Map__mdt would let an admin change a stage map with no deploy and no review, which is the
 * SAME class of hole as the Path button this program removes. It also costs a getAll() per
 * transaction, is not compile-checked against its callers, and — recorded org defect — CMDT *record*
 * deploys fail in this org with UNKNOWN_EXCEPTION and need an Apex loader. A stage change already
 * requires touching the picklist, the pathAssistant and the quick action, all metadata deploys, so
 * the map is not the bottleneck. The Opportunity precedent (StageAdvanceService.NEXT_STAGE) is an
 * Apex map; matching it keeps one pattern.
 *
 * ── LAYERING ─────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It holds ZERO SOQL: every read
 * goes to the object's own selector via selectStageRequiredById. There is deliberately NO dynamic
 * SOQL — a generic Database.query() over seven objects would violate the selector rule, skip
 * WITH USER_MODE and add an injection surface. The cost is a seven-branch dispatch in load(), which
 * is two lines per object and compile-checked.
 *
 * ⚠ Record-type resolution adds ZERO queries. RecordTypeId rides along on the selector read that
 * already happens, and the Id -> developer name step is a DESCRIBE
 * (getRecordTypeInfosById().get(id).getDeveloperName()), not a lookup on RecordType.
 *
 * ── WRITE MODE (design decision D1): plain `update`, i.e. SYSTEM MODE ─────────
 * Matches StageAdvanceService.setStage exactly. The control here is the permission gate plus the
 * (future) validation rule, not FLS; and a silent divergence between two sibling services is itself
 * a defect source. RESIDUAL, accepted and documented: a user with the deal-driver gate but WITHOUT
 * FLS edit on the stage field can still drive the button. Switching to
 * Database.update(record, AccessLevel.USER_MODE) is a one-line change, but FLS truth is not in
 * source control (profiles are .forceignore'd), so it cannot be regression-tested from this repo.
 *
 * ── BULKIFICATION ────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. advance() is a
 * per-transaction-singleton @AuraEnabled operation invoked once per quick-action click: one record,
 * one selector read, one update, no loop over records and no collection DML. Same shape and same
 * exemption as StageAdvanceService and OpportunityActionPermissionService.
 *
 * @see force-app/main/default/classes/StageAdvanceService.cls (the Opportunity sibling)
 * @see force-app/main/default/classes/RecordStageAdvanceController.cls (the LWC boundary)
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (the gate)
 */
public with sharing class RecordStageAdvanceService {

    /**
     * Raised when a record cannot advance and the reason is user-safe and surfaced verbatim:
     * no record supplied, an unsupported object, no stage set, no next step from the current
     * stage, or a platform save block whose validation message is surfaced. Distinct from an
     * unexpected QueryException (missing/inaccessible record), which the controller maps to a
     * fixed generic message instead.
     */
    public class RecordStageAdvanceException extends Exception {}

    /**
     * Raised when the running user may not drive this record's stage action. Owned by THIS class
     * rather than re-thrown from the gate's own type so that adding a second gate (e.g. a Property
     * Management persona on a future object) changes nothing at the controller boundary.
     */
    public class AccessDeniedException extends Exception {}

    /**
     * Which permission gate a RECORD TYPE's stage action answers to. An enum, not a String, so a
     * new object cannot be wired to a gate that does not exist (.claude/rules — "use enums over
     * string constants").
     *
     * ── 🔴 REWRITTEN 2026-08-12: ALL THREE MEMBERS ARE NOW ONE CUSTOM PERMISSION ──
     * This block previously described three DIFFERENT mechanisms and warned "THE THREE MEMBERS ARE
     * NOT ALL THE SAME SHAPE ... do not generalise from the first two". That warning is now
     * OBSOLETE and is rewritten rather than left standing: the `*_Driver__c` flag model was retired
     * entirely and every gate below is a single `FeatureManagement.checkPermission` call plus the
     * shared "Modify All Data" bypass.
     *
     *   DEAL_DRIVER         `Acquisition_Deal_Actions`, granted by `Acquisition_Deal_Driver`.
     *                       The acquisitions deal children. The LOI and Underwriting record pages
     *                       carry the matching Dynamic Actions visibility rule
     *                       `{!$Permission.CustomPermission.Acquisition_Deal_Actions} EQUAL true`,
     *                       so this costs no new machinery.
     *
     *                       🔴 THAT TOKEN HAS THREE SEGMENTS AND THE PLATFORM REJECTS THE OTHER TWO
     *                       SPELLINGS — MEASURED AT DEPLOY 2026-08-12, NOT INFERRED. A FlexiPage
     *                       `<leftValue>` must read `{!$Permission.CustomPermission.<Name>}`. Both
     *                       `{!$Permission.<Name>}` (the two-segment form this comment itself
     *                       carried until it was corrected) and `{!$CustomPermission.<Name>}` were
     *                       REFUSED by the Metadata API, so a rule copied from a shortened comment
     *                       fails the deploy rather than silently mis-evaluating. Keep every written
     *                       occurrence in this repo in the three-segment form for that reason.
     *   DISPOSITION_DRIVER  `Disposition_Deal_Actions`, granted by `Disposition_Deal_Driver`.
     *                       WIRED 2026-08-09 (Tranche 3A, decision D15/Q1). Until then the value
     *                       was deliberately NOT declared: an unwired enum member is
     *                       indistinguishable from a wired one at a glance, and passesGate's
     *                       `when else` would have denied it silently for every disposition user.
     *   TRANSACTION_STAGE_ACTIONS
     *                       `Transaction_Stage_Actions`, granted by
     *                       `Transaction_Stage_Actions_Access`. WIRED 2026-08-12 with the
     *                       Transaction Advance Stage action — for the reason recorded on
     *                       DISPOSITION_DRIVER above.
     *
     * ⚠ THE ENUM VALUE NAMES WERE DELIBERATELY NOT RENAMED. `DEAL_DRIVER` and `DISPOSITION_DRIVER`
     * still read as if a `*_Driver__c` checkbox existed, and it no longer does. They name the GATE
     * (which persona drives this record type), not the MECHANISM, and renaming them is churn across
     * a config map with three call sites and zero behavioural benefit. Read them as "the
     * acquisitions deal-driving persona" / "the disposition deal-driving persona".
     *
     * 🔴 THE ONE ASYMMETRY THAT SURVIVES IS WHICH LAYER CARRIES THE PERMISSION, AND IT MATTERS.
     * `Acquisition_Deal_Actions` and `Disposition_Deal_Actions` sit on LAYER-5 authorization sets
     * assigned DIRECTLY to a narrow population. `Transaction_Stage_Actions` sits on the LAYER-4
     * capability set `Transaction_Stage_Actions_Access`, which is a member of the
     * `DPEG_Transaction_Team` group — so the Transaction gate is TEAM-WIDE and has no per-user
     * revocation, exactly as it was under the membership check it replaced. That is a preserved
     * policy, not an artefact of the migration. Moving either of the first two onto a layer-4 set
     * would be a real WIDENING (`Opportunity_Stage_Actions_Access` is a member of
     * `DPEG_Junior_Analyst_PSG`); moving the third off one would be a real NARROWING. Read
     * TransactionActionPermissionService's header before harmonising any of them.
     *
     * 🔴 THE GATE IS A PROPERTY OF THE RECORD TYPE, NOT OF THE OBJECT — that is the point of
     * wiring it here rather than reusing DEAL_DRIVER for `NDA__c` wholesale. One object serves
     * both modules, and an acquisitions deal driver must not be able to drive a sale's NDA (or
     * the reverse) merely because the two share a table. That stays true for an object with a
     * single sequence: `Transaction__c` names its gate exactly once because it has exactly one
     * sequence, not because the gate is an object-level property.
     *
     * ⚠ A NOTE FOR ANYONE READING THE GIT HISTORY. This block used to argue at length that the two
     * `*_DRIVER` members must NOT become permission-set MEMBERSHIP checks, because a user holding
     * the set with the flag `false` was denied and would have been GRANTED — a silent widening of a
     * live boundary. That argument is now MOOT, not overturned: there is no flag left to disagree
     * with the set, and the custom permission is carried BY those same sets, so the population is
     * preserved by construction. Do not resurrect it as an objection to a future change; the
     * argument that still bites is the layer-4/layer-5 one above.
     */
    public enum StageActionGate {
        DEAL_DRIVER,
        DISPOSITION_DRIVER,
        TRANSACTION_STAGE_ACTIONS
    }

    private static final String NO_RECORD_MESSAGE = 'No record was provided.';
    private static final String UNSUPPORTED_OBJECT_MESSAGE =
        'This action is not available on this record.';
    private static final String NO_STAGE_MESSAGE =
        'This record has no stage set, so it cannot be advanced.';
    /**
     * Distinct from UNSUPPORTED_OBJECT_MESSAGE on purpose: the object IS stage-controlled, but the
     * record sits on a record type this service has no sequence for. Separate wording so the
     * condition is falsifiable in a test and so the reader of a toast can tell "wrong object" from
     * "unconfigured record type" — two different fixes.
     */
    private static final String UNSUPPORTED_RECORD_TYPE_MESSAGE =
        'This action is not configured for this record type.';

    /** The standard field carrying the row's record type. Compared case-insensitively — see recordTypeIdOf. */
    private static final String RECORD_TYPE_ID_FIELD = 'RecordTypeId';

    /**
     * The map key used by an object with NO record types at all — Underwriting__c,
     * Construction_Feasibility_Review__c, Development_Feasibility_Review__c and, since
     * 2026-08-12, Transaction__c.
     *
     * A sentinel rather than a real developer name so it can never collide with one, and so a
     * reader can see at a glance which configs are record-type-aware.
     *
     * ⚠ ITS DOC COMMENT USED TO OFFER A SECOND USE — "or because its types deliberately share one
     * sequence (Contract_Review__c…)" — AND THAT WAS WRONG, corrected in Tranche 3C. Sharing a
     * SEQUENCE is not sharing a GATE, and this key carries BOTH. Contract_Review__c's two types do
     * share their sequence (by reference, one map object) and answer to two DIFFERENT personas, so
     * it is keyed by developer name like NDA__c and LOI__c. There is now no object in the config
     * that has record types AND uses this key, and there should not be one: an object that has
     * record types has, by construction, a question this key cannot answer.
     */
    private static final String SINGLE_TYPE_KEY = '__DEFAULT__';

    /** NDA__c record type developer names (D7 / D14.1). Case must match the metadata exactly. */
    private static final String RT_ACQUISITION_NDA = 'Acquisition_NDA';
    private static final String RT_DISPOSITION_NDA = 'Disposition_NDA';

    /**
     * LOI__c record type developer names (D6, Tranche 3B). Case must match
     * objects/LOI__c/recordTypes/ exactly — these strings are Map keys and Apex Map<String, …>
     * keys are case-SENSITIVE, so a mis-cased constant would route every disposition LOI to the
     * acquisition fallback with no error anywhere.
     */
    private static final String RT_ACQUISITION_LOI = 'Acquisition_LOI';
    private static final String RT_DISPOSITION_LOI = 'Disposition_LOI';

    /**
     * Contract_Review__c record type developer names (D16.3, Tranche 3C). Case must match
     * objects/Contract_Review__c/recordTypes/ exactly — these strings are Map keys and Apex
     * Map<String, …> keys are case-SENSITIVE, so a mis-cased constant would route every
     * disposition PSA to the acquisition fallback with no error anywhere. That degradation is
     * QUIETER here than on NDA__c / LOI__c, because the fallback map is the SAME map and the walk
     * would still work perfectly — only the GATE would be wrong.
     */
    private static final String RT_ACQUISITION_PSA = 'Acquisition_PSA';
    private static final String RT_DISPOSITION_PSA = 'Disposition_PSA';

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE MAPS — current stage -> the single next stage.
    // Each map is one PATH, minus its terminal stage (which has no entry and therefore yields the
    // "no next step available" message). Values are the DECODED runtime picklist strings.
    //
    // ⚠ NO VALUE IN ANY OF THESE TEN MAPS CONTAINS A '/' ANY MORE. This note used to say
    // "'Prepare/Review' carries a literal slash, which is why the future validation rules must use
    // TEXT(...) compares rather than ISPICKVAL" — observation 5 renamed that value to
    // 'Under Review' and it was the last one. The TEXT(...) discipline is still correct for
    // validation rules on these fields (it is what makes a value rename a one-line edit rather
    // than a re-encoded one), but there is no longer a %2F hazard to point at. Opportunity's
    // 'Dead/Pass' still carries it; that is StageAdvanceService's field, not this one.
    //
    // ⚠ An object with record types has ONE MAP PER RECORD TYPE. Do not merge two record types'
    // maps into one even when they share values — see the 'Sent' divergence in the class header.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * NDA__c.Status__c / Acquisition_NDA — Pending -> Sent -> Received -> Signed. 'Signed' is
     * terminal.
     *
     * ⚠ 'Received' was INSERTED between 'Sent' and 'Signed' by decision D14.1 (2026-08-09). The
     * source document describes the acquisition NDA as Pending -> Received -> Signed; D14.1 reads
     * that as the broker-facing milestones and keeps 'Sent' as the internal step it pairs with
     * Date_Sent__c. Retaining 'Sent' is what makes the change ADDITIVE — every existing acquisition
     * NDA keeps a valid value and no row migration is needed for the value set itself.
     */
    private static final Map<String, String> NDA_ACQUISITION_NEXT_STAGE = new Map<String, String>{
        'Pending' => 'Sent',
        'Sent' => 'Received',
        'Received' => 'Signed'
    };

    /**
     * NDA__c.Status__c / Disposition_NDA — Not Sent -> Sent -> Signed. 'Signed' is terminal.
     *
     * 🔴 'Sent' MAPS SOMEWHERE ELSE HERE THAN IT DOES ON THE ACQUISITION MAP ABOVE. That is not an
     * inconsistency to reconcile; it is the requirement. A disposition NDA goes straight from Sent
     * to Signed (there is no "received back from the broker" step on a sale, because DPEG issues
     * the NDA), while an acquisition NDA passes through 'Received'.
     */
    private static final Map<String, String> NDA_DISPOSITION_NEXT_STAGE = new Map<String, String>{
        'Not Sent' => 'Sent',
        'Sent' => 'Signed'
    };

    /**
     * The disposition NDA's off-ramp, reached by the Mark Declined quick action rather than by
     * advance() — 'Declined' is a terminal alternative to 'Signed', not a forward hop, so no single
     * derived target from 'Sent' can express both.
     *
     * 🔴 THIS SET IS THE REASON THE ALLOW-LIST HAD TO BECOME RECORD-TYPE-AWARE. The Mark Declined
     * action keys on Status__c = 'Sent', a value SHARED by both NDA record types (§3.2 of the
     * design). Held at object level, this set would make advanceTo(acquisitionNdaId, 'Declined')
     * succeed, because Apex DML does not enforce record-type picklist restrictions. The acquisition
     * NDA supplies NO explicit targets at all, so advanceTo cannot move it.
     *
     * The action itself is `quickActions/NDA__c.Mark_Declined` -> `c/ndaMarkDeclined`, which
     * passes this exact literal as a module constant. It is no longer "a future action".
     *
     * ⚠ 'Declined' is deliberately NOT in NDA_DISPOSITION_NEXT_STAGE. It is a TERMINAL ALTERNATIVE
     * to 'Signed', not a forward hop — putting it there would make the ordinary Advance Stage
     * button decline the NDA.
     */
    private static final Set<String> NDA_DISPOSITION_EXPLICIT_TARGETS = new Set<String>{
        'Declined'
    };

    /**
     * LOI__c.Stage__c / Acquisition_LOI — Draft -> Under Review -> Submitted -> Negotiation ->
     * Signed. 'Signed' is terminal.
     *
     * 🔴 EVERY VALUE BUT 'Draft' CHANGED (Acquisition Observations, observation 5, 2026-08-14).
     * The old map read Draft -> Prepare/Review -> Sent -> Counter -> Completed. The rename is
     * one-for-one and preserves the SHAPE exactly — same five stages, same branch point, same
     * terminal — so nothing below this map moved:
     *
     *   Prepare/Review -> Under Review     ('Under Review' ALREADY EXISTED on this picklist)
     *   Sent           -> Submitted
     *   Counter        -> Negotiation
     *   Completed      -> Signed
     *
     * ⚠ 'Draft' IS THE ONLY SURVIVING LITERAL, and that is what keeps OpportunityReviewService's
     * LOI seed stage (`Stage__c = 'Draft'`) and TestDataFactory's LOI fixture correct with no edit.
     * Do not read that as "the LOI half was small".
     *
     * 🔴 THE SLASH IS GONE, AND WITH IT THE %2F HAZARD ON THIS MAP. 'Prepare/Review' carried a
     * literal slash, which is why every validation rule keyed on this field was required to use
     * TEXT(...) rather than ISPICKVAL and why the value appears as `Prepare%2FReview` in some
     * metadata contexts. NOT ONE value in the new sequence contains a '/', so no encoding applies
     * to any of them. Do not "helpfully" encode 'Under Review' — it is two words and a space.
     * (`Dead/Pass` on Opportunity.StageName is a different field and still carries the trap.)
     *
     * 🔴 'Under Review' IS NOW SHARED WITH Disposition_LOI, WHICH BREAKS THE DISJOINTNESS THE
     * WHOLE LOI FEATURE USED TO ASSUME. See the class header's rewritten LOI block: the two stage
     * sets are no longer disjoint, so a rule, formula or hint keyed on the STAGE VALUE ALONE can no
     * longer identify which side of the business a row belongs to. Nothing in THIS class regressed
     * — it has always resolved the sequence from the RECORD TYPE and never from the stage — but the
     * three arguments in the header for why that was the right choice have gone from "belt and
     * braces" to "the only thing holding this together".
     */
    private static final Map<String, String> LOI_ACQUISITION_NEXT_STAGE = new Map<String, String>{
        'Draft' => 'Under Review',
        'Under Review' => 'Submitted',
        'Submitted' => 'Negotiation',
        'Negotiation' => 'Signed'
    };

    /**
     * LOI__c.Stage__c / Disposition_LOI — Received -> Under Review -> Countered by DPEG ->
     * Counter Received from Buyer -> Executed. 'Executed' is terminal.
     *
     * 🔴 THE DIRECTION IS REVERSED, WHICH IS WHY THIS IS A SECOND MAP RATHER THAN A LONGER ONE.
     * On a purchase DPEG DRAFTS the LOI and SENDS it, so the path starts at 'Draft'. On a sale the
     * LOI ARRIVES from the buyer through the appointed broker, so it starts at 'Received' — there
     * is no Draft and no Submitted.
     *
     * 🔴 THE SENTENCE THAT USED TO END THAT PARAGRAPH — "Not one value is shared with the
     * acquisition map" — IS FALSE SINCE 2026-08-14 and is the single most quotable casualty of
     * observation 5. 'Under Review' is now on BOTH maps: it is the acquisition sequence's second
     * stage (renamed from 'Prepare/Review') and this map's second stage. This map itself is
     * UNCHANGED — the sell side was not touched by observation 5 — but anything that inferred
     * "which side is this?" from an LOI stage value alone is now wrong, and the LOI record-type
     * files, the LOI record page's visibility rules and LOI__c.Is_Advance_Allowed__c all did
     * exactly that (design collision C1). This service does not, and never did.
     *
     * ✅ THE "OPEN" NOTE THAT USED TO SIT HERE IS CLOSED — see LOI_DISPOSITION_EXPLICIT_TARGETS
     * immediately below. This map stays exactly as it was: it is the LINE through the loop, and the
     * two loop edges are reached by advanceTo() instead. The line is what advance() walks, so
     * 'Counter Received from Buyer' still derives 'Executed' and never derives a cycle.
     */
    private static final Map<String, String> LOI_DISPOSITION_NEXT_STAGE = new Map<String, String>{
        'Received' => 'Under Review',
        'Under Review' => 'Countered by DPEG',
        'Countered by DPEG' => 'Counter Received from Buyer',
        'Counter Received from Buyer' => 'Executed'
    };

    /**
     * The sell-side NEGOTIATION LOOP, reached by two named quick actions rather than by advance().
     *
     * 🔴 THIS SET EXISTS BECAUSE A Map<String, String> CANNOT HOLD A CYCLE. The document (Part 2
     * line 244) says the negotiation "goes round until both sides are agreed", so
     * 'Countered by DPEG' <-> 'Counter Received from Buyer' is a two-edge cycle. LOI_DISPOSITION_-
     * NEXT_STAGE holds ONE value per key, so it can express at most one of those edges; the other
     * — the BACK-edge from 'Counter Received from Buyer' to 'Countered by DPEG' — is provably
     * unreachable through advance() at any price. That is what an explicit target is for.
     *
     * ⚠ BOTH EDGES ARE LISTED, NOT JUST THE BACK-EDGE, AND THAT IS DELIBERATE.
     * 'Counter Received from Buyer' IS the derived hop from 'Countered by DPEG', so listing it here
     * makes c/loiMarkCounterReceived overlap c/advanceRecordStage at that one stage. Two reasons
     * that beat the tidier one-edge version, both recorded on
     * quickActions/LOI__c.Mark_Counter_Received:
     *   1. SYMMETRY — a user driving a loop should see the same shape of control at both of its
     *      stages; naming one direction and leaving the other as an anonymous "advance" invites a
     *      guess about which button does what.
     *   2. INDEPENDENCE — if a later change re-points the derived hop out of 'Countered by DPEG',
     *      a page relying on Advance Stage for that edge silently loses it. An explicit target
     *      cannot drift that way.
     * The cost is one redundant button on one stage. Do not "tidy" this down to one entry without
     * moving the other edge somewhere it can be expressed, which today is nowhere.
     *
     * 🔴 IT IS PER RECORD TYPE, AND THAT IS THE SECURITY HALF — NOT A TIDY-UP. Neither value exists
     * on Acquisition_LOI's value set, and Apex DML DOES NOT ENFORCE record-type picklist
     * restriction, so an object-level list would let advanceTo(acquisitionLoiId, 'Countered by
     * DPEG') park a purchase on a sell-side stage that matches neither the acquisition Path nor any
     * flexipage rule keyed on it. Exactly the hole NDA__c's 'Declined' target opened one tranche
     * earlier. Pinned by acquisitionLoiRefusesADispositionStageAsAnExplicitTarget (the refusal) and
     * dispositionLoiAcceptsTheNegotiationLoopTargets (its complement — without which the refusal
     * could pass simply because these values were configured nowhere at all).
     *
     * ⚠ NEITHER VALUE IS A DERIVABLE FORWARD HOP OUT OF ITS OWN SOURCE STAGE IN THE SENSE THAT
     * MATTERS: adding an explicit target never lets a caller SKIP a hop here, because both stages
     * sit adjacent in the sequence. Contrast LOI_ACQUISITION_EXPLICIT_TARGETS, which deliberately
     * excludes 'Under Review' and 'Submitted' precisely because listing them WOULD skip the
     * approval gate (those two were 'Prepare/Review' and 'Sent' until observation 5 renamed them;
     * the exclusion is unchanged). There is no equivalent gate on the sell side — the disposition
     * LOI has no approval process — so no transition is bypassed by these two entries.
     *
     * The actions are `quickActions/LOI__c.Mark_Countered_By_DPEG` -> `c/loiMarkCounteredByDpeg`
     * and `quickActions/LOI__c.Mark_Counter_Received` -> `c/loiMarkCounterReceived`; each passes
     * its value as a hardcoded module constant, which is the property that makes this list
     * meaningful.
     *
     * ⚠ 'Executed' is deliberately NOT here. It is the derived hop from 'Counter Received from
     * Buyer' and belongs to advance(); listing it would add a second route to the terminal stage
     * for no gain. 'Received' and 'Under Review' are absent for the same reason.
     */
    private static final Set<String> LOI_DISPOSITION_EXPLICIT_TARGETS = new Set<String>{
        'Countered by DPEG',
        'Counter Received from Buyer'
    };

    /**
     * Contract_Review__c.Negotiation_Status__c / Acquisition_PSA — Draft -> Negotiation -> Signed
     * -> Executed. 'Executed' is terminal.
     *
     * ── 🔴 THE SHARED MAP IS GONE. THIS IS THE SPLIT ITS OWN COMMENT PREDICTED. ──
     * Until 2026-08-14 there was ONE map object, `CONTRACT_REVIEW_NEXT_STAGE`, that BOTH record
     * types pointed at BY REFERENCE, and the class header argued at length that copying it "would
     * invite the two to drift apart while the requirement is that they cannot". That argument was
     * correct for as long as its premise held — Disposition_PSA's record type file recorded that
     * `Initial Draft -> Revised -> Ready for Execution -> Executed` were ALREADY exactly the
     * sell-side states, so the two sides had nothing to disagree about.
     *
     * Observation 7 (Acquisition Observations, 2026-08-14) ends that premise. The ACQUISITION PSA
     * moves to `Draft -> Negotiation -> Signed -> Executed`; the DISPOSITION PSA keeps its four
     * values verbatim. The two sequences now genuinely differ, so the old block's own escape clause
     * applies literally: *"IF THE TWO SIDES EVER DO DIVERGE, SPLIT INTO TWO NAMED MAPS — do not add
     * a value here and restrict it in the record type file."* That is exactly what happened, and it
     * is why the split is CORRECT here and would have been a defect a week ago.
     *
     * 🔴 THE ALTERNATIVE THE OLD COMMENT FORBIDS IS THE ONE THAT LOOKS CHEAPEST, SO NAME IT: adding
     * `Draft`/`Negotiation`/`Signed` to a single shared map and relying on the record type files to
     * keep them off the sell side. Record-type picklist restriction is UI-ONLY and is not enforced
     * by Apex DML, so `advance()` ITSELF would then write an acquisition-only status onto a
     * disposition PSA — not a hand-crafted call, the ordinary Advance Stage button. Two maps is the
     * only shape in which that is unexpressible.
     *
     * ⚠ 'Executed' IS THE ONE VALUE STILL SHARED BY BOTH SEQUENCES, and it is deliberately the
     * TERMINAL of both — so it has no entry in either map and can never derive a hop on the wrong
     * side. That is what keeps the `Executed` handoff (see below) identical for both modules.
     *
     * 🔴 THIS OBJECT'S STAGE FIELD IS Negotiation_Status__c, NOT Stage__c — THE ONLY EXCEPTION
     * BESIDES THE NDA, AND FOR A COMPLETELY DIFFERENT REASON.
     * The NDA simply names its field Status__c. Here, Stage__c is a DERIVED PROJECTION that CANNOT
     * be written at all: the active before-save flow Contract_Review_Stage_Sync recomputes it from
     * Negotiation_Status__c on every create and update. A first attempt at this object mapped
     * Stage__c directly and produced a button that reported SUCCESS and changed nothing — the DML
     * committed, LastModifiedDate moved, and the flow had already replaced the value (measured
     * 2026-08-05 on CTR-0000). Driving the status is what makes the Path move, as a consequence —
     * and this projection is now PER RECORD TYPE too, because the flow maps status values and the
     * status values differ:
     *
     *   ACQUISITION (this map)          DISPOSITION (CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE)
     *   Draft       -> 'PSA Drafting'   Initial Draft       -> 'PSA Drafting'
     *   Negotiation -> 'Review'         Revised             -> 'Review'
     *   Signed      -> 'Review'         Ready for Execution -> 'Review'
     *   Executed    -> 'Contract        Executed            -> 'Contract Execution'
     *                   Execution'
     *
     * 🔴 THE 'Draft' ROW IS A DEPENDENCY ON A FLOW THIS CLASS DOES NOT OWN, AND IT FAILS QUIETLY.
     * `Contract_Review_Stage_Sync` is a before-save flow with an explicit rule for 'Initial Draft'
     * and a DEFAULT connector sending everything else to `Stage__c = 'Review'`. Until that flow
     * learns 'Draft' (design collision C4, owned by the declarative half of this pack), a brand-new
     * acquisition PSA shows the coarse 'Review' instead of 'PSA Drafting' — it deploys green,
     * nothing errors, and no Apex test can see it, because `Stage__c` is derived and writing it
     * from here commits and is silently discarded. The flow must learn 'Draft' while KEEPING
     * 'Initial Draft', which the disposition side still runs on.
     *
     * ⚠ TWO CONSEQUENCES WORTH KNOWING BEFORE EDITING EITHER MAP.
     * 1. The MIDDLE hop leaves the PATH UNCHANGED on both sides (Negotiation -> Signed on the
     *    acquisition map, Revised -> Ready for Execution on the disposition one; all four project
     *    to 'Review'), so the user sees a success toast and a stationary Path. That is correct, not
     *    a repeat of the defect above — the status genuinely advanced.
     * 2. The final hop into 'Executed' is NOT just a status write, on EITHER map. It fires
     *    ContractReviewTrigger -> ContractExecutionService, and since Tranche 3C that service has
     *    TWO ARMS keyed on which parent lookup is populated:
     *      Opportunity__c set -> stamps the Opportunity (Contract Signed, Day 0) + 3 notifications
     *      Disposition__c set -> moves Disposition__c.Disposition_Stage__c to 'Closing'
     *    Adding or reordering entries around 'Executed' changes when BOTH handoffs fire. ⚠ Note the
     *    PREDECESSOR of that hop now differs by side ('Signed' vs 'Ready for Execution'), which is
     *    the one place the split changes the shape of the handoff rather than just its labels.
     *    ⚠ The sentence here used to say this hop "CREATES THE Transaction__c". That has been
     *    FALSE since 2026-08-05 — creation moved to ContractExecutionService
     *    .openTransactionsOnAboutToClose, keyed on Opportunity.StageName = 'About to Close'. The
     *    hop still stamps the Day-0 DATE that the later creation reads back, so the two remain
     *    coupled; they simply no longer run together.
     *
     * Seller Counter and Buyer Counter are deliberately absent: they are branch states, and the
     * user chose (2026-08-05) to record them by editing the field rather than with named buttons.
     * Adding them later means an explicit-target allow-list, exactly as the LOI has. Neither PSA
     * record type supplies an explicit target today, so advanceTo() is structurally unreachable on
     * this object — the split did not change that.
     */
    private static final Map<String, String> CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE =
        new Map<String, String>{
            'Draft' => 'Negotiation',
            'Negotiation' => 'Signed',
            'Signed' => 'Executed'
        };

    /**
     * Contract_Review__c.Negotiation_Status__c / Disposition_PSA — Initial Draft -> Revised ->
     * Ready for Execution -> Executed. 'Executed' is terminal.
     *
     * 🔴 THIS MAP IS THE OLD SHARED ONE, VERBATIM AND UNCHANGED. Observation 7 is an ACQUISITION-
     * ONLY change: `Disposition_PSA`'s own record type file records that these four values are
     * already exactly the states the client document names for the sell-side PSA, and O3 of the
     * requirements doc states as a HARD STOP that `Initial Draft` / `Revised` /
     * `Ready for Execution` remain ACTIVE on the field precisely because this record type still
     * runs on them. Nothing is deactivated on `Negotiation_Status__c` by this pack.
     *
     * ⚠ SO THE COST OF THE SPLIT LANDS ENTIRELY HERE, AND IT IS THE COST THE OLD SHARED-REFERENCE
     * COMMENT WARNED ABOUT: there are now two things that must be maintained separately, and a
     * change made to the acquisition sequence will NOT reach this one. That is the requirement now
     * rather than the hazard — but a future editor adding a stage to one map must consciously
     * decide about the other rather than getting it for free. `DispositionStageEntryService`'s
     * `DISPOSITION_PSA_INITIAL_STATUS = 'Initial Draft'` is this map's entry point and is the thing
     * to check first; `DispositionStageEntryServiceTest` pins it.
     */
    private static final Map<String, String> CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE =
        new Map<String, String>{
            'Initial Draft' => 'Revised',
            'Revised' => 'Ready for Execution',
            'Ready for Execution' => 'Executed'
        };

    /**
     * 🔴 THE ACQUISITION LOI PATH IS NOT LINEAR (2026-08-05) — it branches at 'Submitted'.
     *
     * At 'Submitted' a broker either counters or accepts, so the deal driver gets two named buttons
     * instead of one generic Advance Stage: Negotiation and Signed. 'Signed' cannot be reached by
     * advance() from 'Submitted' — LOI_ACQUISITION_NEXT_STAGE derives 'Negotiation' — so it needs
     * an explicit target.
     *
     * ⚠ BOTH VALUES WERE RENAMED IN PLACE (observation 5, 2026-08-14): 'Counter' -> 'Negotiation'
     * and 'Completed' -> 'Signed'. The MEMBERSHIP is unchanged — same two stages, same branch, same
     * reasoning — so this is a rename and not a widening. The two bundles that send these literals,
     * c/loiMarkCountered and c/loiMarkCompleted, were repointed in the same change and still pass
     * them as hardcoded module constants, which is the property that makes this list meaningful.
     *
     * Membership is limited to the two stages that legitimately have no single derivable
     * predecessor from 'Submitted'. 'Under Review' and 'Submitted' are deliberately EXCLUDED — they
     * are derivable forward hops belonging to advance(), and listing them would let a direct Apex
     * call skip the approval gate the LOI page enforces at the review stage.
     *
     * 🔴 EXCLUDING 'Under Review' IS NOW LOAD-BEARING FOR A SECOND, NEWER REASON. That value is
     * SHARED with Disposition_LOI since observation 5 (it is the sell-side's second stage). Listing
     * it here would therefore not merely skip a hop — it would put a value BOTH record types carry
     * onto an acquisition-scoped allow-list, which is precisely the shape of leak the per-record-
     * type split exists to prevent. The two allow-lists remain fully disjoint even though the two
     * SEQUENCES no longer are, and that disjointness is what
     * acquisitionLoiRefusesADispositionStageAsAnExplicitTarget /
     * dispositionLoiRefusesTheAcquisitionExplicitTargets still measure.
     *
     * 🔴 THIS SET WAS OBJECT-LEVEL UNTIL TRANCHE 3B AND IS NOW PER RECORD TYPE. Neither value
     * exists on Disposition_LOI's value set, and Apex DML does not enforce record-type picklist
     * restriction — so an object-level list would let advanceTo(dispositionLoiId, 'Signed')
     * write an acquisition-only stage onto a sale, exactly the hole the NDA's 'Declined' target
     * opened one tranche earlier.
     *
     * ⚠ 'Signed' IS A PARTICULARLY BAD VALUE TO LEAK ONTO A SALE, which the pre-observation-5
     * 'Completed' was not: a sell-side reader seeing 'Signed' on a disposition LOI has no reason to
     * doubt it — the word is plausible on either side of a deal — whereas 'Completed' at least read
     * as vocabulary from the other module. The refusal is the only thing that catches it.
     *
     * ⚠ THE SENTENCE THAT USED TO END THIS BLOCK — "the disposition type supplies NO explicit
     * targets at all, which makes advanceTo() structurally unreachable for it" — WAS TRUE ONLY
     * UNTIL THE 3B CLOSE-OUT AND IS NOW FALSE. Disposition_LOI has its own two-value set
     * (LOI_DISPOSITION_EXPLICIT_TARGETS, the negotiation loop). The leak is therefore live in BOTH
     * directions and both are tested.
     */
    private static final Set<String> LOI_ACQUISITION_EXPLICIT_TARGETS = new Set<String>{
        'Negotiation',
        'Signed'
    };

    /**
     * Underwriting__c.Stage__c.
     *
     * 🔴 THE 'In Progress' -> 'Approved' HOP IS DELIBERATELY ABSENT. IT IS NOT AN OVERSIGHT.
     *
     * 'Approved' is owned by the PRINCIPAL APPROVAL PROCESS. A naive "same as the other objects"
     * copy would put Approved one button-click away and bypass the approval entirely — the deal
     * would show a principal-approved underwriting that no principal ever saw. The already-deployed
     * `Underwriting__c.Submit_for_Approval` quick action (OpportunityApprovalController ->
     * OpportunityApprovalService) is the route from 'In Progress', and ApprovalAuditService stamps
     * Stage__c = 'Approved' on principal sign-off.
     *
     * From 'In Progress' this service therefore refuses, with wording that NAMES the real route
     * (see NO_NEXT_STEP_HINTS) so the omission reads as a rule rather than a bug.
     *
     * Exactly the same shape as StageAdvanceService.NEXT_STAGE deliberately omitting 'Underwriting'
     * for exactly the same reason.
     *
     * ⚠ ApprovalAuditService's stamp is Apex DML inside a try/catch that SWALLOWS the DmlException,
     * so any future validation rule on Underwriting__c.Stage__c MUST explicitly permit the
     * transition into 'Approved' — a rule that blocks it fails silently and the Path simply never
     * reaches Approved (design doc §7.3).
     */
    private static final Map<String, String> UNDERWRITING_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'In Progress',
        // 'In Progress' => (no entry) — reaching 'Approved' is the approval process's job.
        'Approved' => 'Completed'
    };

    /**
     * Construction_Feasibility_Review__c.Stage__c —
     * Requested -> Site Visit -> Condition Assessment -> Cost Estimate -> Share Opinion -> Completed.
     */
    private static final Map<String, String> CONSTRUCTION_REVIEW_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'Site Visit',
        'Site Visit' => 'Condition Assessment',
        'Condition Assessment' => 'Cost Estimate',
        'Cost Estimate' => 'Share Opinion',
        'Share Opinion' => 'Completed'
    };

    /**
     * Development_Feasibility_Review__c.Stage__c —
     * Requested -> Feasibility analysis -> Vendor proposals -> Share Opinion -> Completed.
     * ⚠ 'Feasibility analysis' and 'Vendor proposals' are lower-cased on their second word in the
     * picklist metadata. The literals here match the org exactly; "correcting" the casing yields a
     * map that silently never matches.
     */
    private static final Map<String, String> DEVELOPMENT_REVIEW_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'Feasibility analysis',
        'Feasibility analysis' => 'Vendor proposals',
        'Vendor proposals' => 'Share Opinion',
        'Share Opinion' => 'Completed'
    };

    /**
     * Transaction__c.Stage__c —
     * Open Contract -> Due Diligence -> Closing Prep -> Post-Closing -> Closed Won.
     * 'Closed Won' is terminal and therefore has NO entry.
     *
     * 🔴 THE ORDER IS A USER DECISION, NOT A DERIVATION, AND IT IS THE ONE THING HERE THAT CANNOT
     * BE WRONG QUIETLY. The picklist's element order and the Transaction Path's step order both
     * read `… Closing Prep -> Post-Closing -> Closed Won`, but the Path's own step TEXT argues the
     * other way — 'Closed Won' says "Transaction closed and funded" while 'Post-Closing' says
     * "Complete the post-closing checklist and file recorded documents", and funding precedes
     * post-closing work in a real deal. Whichever order is configured becomes the ONLY order the
     * button offers, with nothing to signal a mistake. The sequence above was CONFIRMED BY THE
     * USER at Gate 1 on 2026-08-12 against the org's live picklist. Do not "correct" it from the
     * step text; re-ask.
     *
     * ⚠ THERE IS NO EXPLICIT-TARGET ALLOW-LIST FOR THIS OBJECT, DELIBERATELY. The path is a
     * straight line — no branch, no off-ramp, no loop — so every hop is derivable and advance()
     * reaches all of them. An empty allow-list makes advanceTo() STRUCTURALLY UNREACHABLE here,
     * which is the strongest available guarantee that a hand-crafted call cannot skip Due
     * Diligence and land a deal on 'Closed Won'. Adding a target is a real widening: do it only
     * when a named quick action needs a stage advance() cannot derive.
     *
     * ⚠ `Transaction__c` HAS NO RECORD TYPES, so this is a SINGLE-SEQUENCE config (see
     * CONFIG_BY_TYPE) and there is no second map to keep in step. If it is ever given record
     * types, TransactionSelector.selectStageRequiredById must start selecting RecordTypeId in the
     * same change — omitting it degrades SILENTLY to this sequence rather than failing.
     *
     * ⚠ `Closed Lost` DOES NOT EXIST on this picklist (five restricted values, verified in the org
     * 2026-08-12). `lwc/activeTransactionsList` carries a dead pill-map entry for it; that is a
     * cosmetic leftover, not a stage this map is missing.
     */
    private static final Map<String, String> TRANSACTION_NEXT_STAGE = new Map<String, String>{
        'Open Contract' => 'Due Diligence',
        'Due Diligence' => 'Closing Prep',
        'Closing Prep' => 'Post-Closing',
        'Post-Closing' => 'Closed Won'
    };

    /**
     * Stage-specific wording for a refused advance, keyed `<StageConfig.label>|<currentStage>`.
     *
     * Keyed on the config's own label rather than on the SObjectType so no key depends on
     * SObjectType.toString(), which is undocumented.
     *
     * Only populated where the absence of a hop is a RULE rather than the end of the path. Without
     * this, the Underwriting refusal reads exactly like a terminal stage and looks like a defect;
     * with it, the message names the action that actually performs the transition.
     *
     * ⚠ DELIBERATELY NOT record-type-aware. THIS MAP HAS EXACTLY ONE ENTRY AND IT IS ON
     * Underwriting__c, an object with NO record types at all — so today the question cannot arise.
     * That is what makes the omission safe; the per-object reasoning below is about what a FUTURE
     * entry would have to check.
     *
     * 🔴 THE SAFETY ARGUMENT FOR LOI__c CHANGED ON 2026-08-14 AND IS NOW WEAKER. This block used to
     * read: "NDA__c: the only shared stage values ('Sent', 'Signed') have a hop or are terminal on
     * BOTH record types, so neither reaches this map. LOI__c: the two value sets are fully
     * DISJOINT, so a key can only ever match one record type's stage in the first place." The NDA
     * half still holds. The LOI half is FALSE — observation 5 made 'Under Review' a stage on BOTH
     * LOI record types, so a hint keyed `LOI|Under Review` would now fire on a purchase AND a sale
     * with one wording. There is no such key today, which is the only reason this is a note rather
     * than a defect.
     *
     * ⇒ BEFORE ADDING ANY LOI ENTRY HERE, widen the key to
     * `<label>|<recordTypeKey>|<currentStage>` rather than adding a second map. Contract_Review__c
     * needs no such care: observation 7 left its two sequences sharing only 'Executed', which is
     * terminal on both and therefore takes the default wording correctly on either side.
     */
    private static final Map<String, String> NO_NEXT_STEP_HINTS = new Map<String, String>{
        'Underwriting|In Progress' =>
            'Underwriting moves to Approved through the principal approval, not this action. '
            + 'Use Submit for Approval.'
    };

    /**
     * ONE record type's stage sequence: the permission gate, the derived-hop map, and the explicit
     * targets advanceTo() may write for that record type and no other.
     *
     * These three travel together on purpose. They are the only pieces of configuration that
     * differ per record type, and separating them into parallel maps keyed by developer name would
     * let one be extended without the others — which is exactly the half-finished shape this
     * change exists to avoid (a record-type-aware nextStage with an object-wide allow-list, or an
     * object-wide gate).
     *
     * ⚠ THE GATE MOVED HERE FROM StageConfig ON 2026-08-09, and that is a real behavioural change,
     * not a refactor: `NDA__c`'s two record types now answer to two DIFFERENT personas — and since
     * Tranche 3C so do `Contract_Review__c`'s, which is the case that PROVES `gate` and `nextStage`
     * are INDEPENDENT axes: those two types share one `nextStage` map object and differ ONLY in
     * this field. The three record-type-free objects each name their gate exactly once, so nothing
     * about them changed.
     */
    private class StageTypeConfig {
        /** The permission gate this RECORD TYPE's stage actions answer to. */
        private final StageActionGate gate;
        private final Map<String, String> nextStage;
        /**
         * The ONLY stages advanceTo() will write for this record type. Empty for a linear sequence,
         * which makes advanceTo() structurally unreachable there.
         */
        private final Set<String> explicitTargets;

        /** Linear sequence: no branch, so no explicit target is permitted at all. */
        private StageTypeConfig(StageActionGate gate, Map<String, String> nextStage) {
            this(gate, nextStage, new Set<String>());
        }

        private StageTypeConfig(
            StageActionGate gate,
            Map<String, String> nextStage,
            Set<String> explicitTargets
        ) {
            this.gate = gate;
            this.nextStage = nextStage;
            this.explicitTargets = explicitTargets;
        }
    }

    /**
     * Per-OBJECT configuration: display label, stage field API name, and the per-RECORD-TYPE
     * sequences (each of which carries its own permission gate).
     *
     * ⚠ THE GATE IS NO LONGER HERE. It moved onto StageTypeConfig on 2026-08-09 when
     * DISPOSITION_DRIVER was wired, because `NDA__c`'s two record types answer to two different
     * personas. Nothing on this class is record-type-invariant except the label and the stage
     * FIELD — and the field genuinely is: a record type cannot change which column a stage lives
     * in.
     */
    private class StageConfig {
        private final String label;
        private final String stageField;
        /**
         * The key used when the row's record type is null or Master.
         *
         * 🔴 INVARIANT: it MUST be a key of byRecordType. Both constructors below satisfy it by
         * construction, and the config is a single static literal a reviewer reads in one screen —
         * so this is deliberately not re-checked at runtime, which would add an unreachable branch
         * to a class whose coverage is otherwise all live code. A violation surfaces immediately as
         * a NullPointerException inside sequenceFor(), on the first click, for every record.
         */
        private final String defaultTypeKey;
        /** Sequences keyed by record type DEVELOPER NAME, or by SINGLE_TYPE_KEY when invariant. */
        private final Map<String, StageTypeConfig> byRecordType;

        /** An object whose sequence does not vary by record type. */
        private StageConfig(
            String label,
            String stageField,
            StageTypeConfig onlySequence
        ) {
            this(label, stageField, SINGLE_TYPE_KEY,
                new Map<String, StageTypeConfig>{ SINGLE_TYPE_KEY => onlySequence });
        }

        private StageConfig(
            String label,
            String stageField,
            String defaultTypeKey,
            Map<String, StageTypeConfig> byRecordType
        ) {
            this.label = label;
            this.stageField = stageField;
            this.defaultTypeKey = defaultTypeKey;
            this.byRecordType = byRecordType;
        }
    }

    /**
     * The whole feature's configuration, keyed by SObjectType TOKEN (not by name String) so every
     * key is compile-checked and a renamed object breaks the build instead of silently disabling
     * the action.
     *
     * ⚠ NDA__c's stage field is `Status__c` and Contract_Review__c's is `Negotiation_Status__c`;
     * the other four use `Stage__c`. That difference is the reason this config carries the field
     * name per object rather than hardcoding `Stage__c`.
     *
     * ✅ ADDING LOI__c's TWO RECORD TYPES (Tranche 3B) AND THEN Contract_Review__c's (Tranche 3C)
     * WERE CONFIG ADDITIONS, NOT REFACTORS — EXACTLY AS THIS NOTE PREDICTED, BOTH TIMES. 3B cost
     * four edits (the five-argument constructor, two sequences, defaultTypeKey, RecordTypeId on
     * LoiSelector). 3C cost THREE: the five-argument constructor, the two record-type constants,
     * and RecordTypeId on ContractReviewSelector.selectStageRequiredById. It needed NO new sequence
     * at all — both its types pointed at ONE map by reference — which is the case this seam was
     * never explicitly designed for and absorbed anyway.
     *
     * ✅ AND A THIRD TIME, THE HARDEST ONE, IN THE OPPOSITE DIRECTION. Observation 7 (2026-08-14)
     * UNDID 3C's shared map: Acquisition_PSA and Disposition_PSA now hold two DIFFERENT sequences.
     * That cost exactly TWO edits below — renaming one map and adding a second — plus the
     * defaultTypeKey re-argument in the Contract_Review__c entry. So the seam absorbed a
     * convergence AND a divergence at the same cost.
     *
     * NOT ONE LINE BELOW THIS MAP HAS CHANGED SINCE 3A — advance(), advanceTo(), sequenceFor(),
     * gateFor(), load() and setStage() are byte-identical, through three record-type changes and
     * one full value-set rename. That is the property the 3A seam was built for.
     */
    private static final Map<Schema.SObjectType, StageConfig> CONFIG_BY_TYPE =
        new Map<Schema.SObjectType, StageConfig>{
            // ⚠ THREE record-type-aware objects since Tranche 3C (NDA__c here, LOI__c and
            // Contract_Review__c below), and ALL THREE split their two types across DIFFERENT
            // PERSONAS. defaultTypeKey is the
            // ACQUISITION sequence on both so Master / pre-migration rows keep advancing — and,
            // note, keep answering to DEAL_DRIVER, which is the conservative fallback: it grants
            // the disposition buttons to nobody new during the deploy window rather than to
            // everybody.
            NDA__c.SObjectType => new StageConfig(
                'NDA', 'Status__c',
                RT_ACQUISITION_NDA,
                new Map<String, StageTypeConfig>{
                    RT_ACQUISITION_NDA => new StageTypeConfig(
                        StageActionGate.DEAL_DRIVER, NDA_ACQUISITION_NEXT_STAGE),
                    RT_DISPOSITION_NDA => new StageTypeConfig(
                        StageActionGate.DISPOSITION_DRIVER,
                        NDA_DISPOSITION_NEXT_STAGE, NDA_DISPOSITION_EXPLICIT_TARGETS)
                }),
            // Tranche 3B (D6). ⚠ The two stage sets are DISJOINT, unlike NDA__c's — but that buys
            // nothing here; see the class header for the three reasons this service still needs the
            // record type. defaultTypeKey is Acquisition_LOI: every LOI in the org today is
            // buy-side by construction, because the Disposition__c lookup arrives in this tranche.
            LOI__c.SObjectType => new StageConfig(
                'LOI', 'Stage__c',
                RT_ACQUISITION_LOI,
                new Map<String, StageTypeConfig>{
                    RT_ACQUISITION_LOI => new StageTypeConfig(
                        StageActionGate.DEAL_DRIVER,
                        LOI_ACQUISITION_NEXT_STAGE, LOI_ACQUISITION_EXPLICIT_TARGETS),
                    // ⚠ The sell-side path is a LOOP, not a line: its two explicit targets are the
                    // two edges of the Countered by DPEG <-> Counter Received from Buyer cycle,
                    // which a Map<String,String> cannot hold. This set is ALSO what refuses
                    // 'Negotiation' and 'Signed' here — see LOI_ACQUISITION_EXPLICIT_TARGETS — and
                    // is what stops its own two values being written onto an acquisition LOI.
                    RT_DISPOSITION_LOI => new StageTypeConfig(
                        StageActionGate.DISPOSITION_DRIVER,
                        LOI_DISPOSITION_NEXT_STAGE, LOI_DISPOSITION_EXPLICIT_TARGETS)
                }),
            // ⚠ 'Negotiation_Status__c', NOT 'Stage__c' — Stage__c is derived and unwritable here.
            // See CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE above before changing this (renamed from
            // CONTRACT_REVIEW_NEXT_STAGE when the shared map was split on 2026-08-14).
            //
            // ✅ TRANCHE 3C, 2026-08-09 — SPLIT EXACTLY AS THE NOTE THAT USED TO SIT HERE
            // PREDICTED, on the GATE axis only. 🔴 SPLIT AGAIN 2026-08-14 (observation 7) on the
            // SEQUENCE axis, which is the axis 3C explicitly did NOT need: the two types now point
            // at TWO DIFFERENT MAPS, not one shared object. The comment that used to end this block
            // — "Same map OBJECT, not a copy — divergence is unexpressible by construction" — is
            // GONE, not merely reworded. Divergence is now the requirement.
            //
            // 🔴 THE TWO StageTypeConfigs NOW DIFFER IN BOTH ARGUMENTS. Neither may be collapsed:
            //   - the GATE, because a disposition persona does not hold Acquisition_Deal_Actions
            //     (the two module permissions are carried by disjoint sets, measured), so
            //     DEAL_DRIVER refuses every sell-side PSA and the feature is dead for the only
            //     persona that owns it. ⚠ The mechanism named here was FLS on User.Deal_Driver__c
            //     until 2026-08-12; the flag is retired, the argument is not.
            //   - the SEQUENCE, because sharing one map after observation 7 would require the
            //     acquisition-only values to sit on a map the disposition type also walks, and
            //     Apex DML does not enforce record-type picklist restriction — advance() itself
            //     would then park a sale on an acquisition-only status.
            //
            // ── 🔴 defaultTypeKey WAS RE-CHOSEN DELIBERATELY, NOT LEFT ALONE (design C9) ──
            // It STAYS Acquisition_PSA — but the ARGUMENT for it is completely different and the
            // old one is dead. Until observation 7, both types shared one sequence, so a Master /
            // pre-T-B row advanced CORRECTLY through the fallback and the only thing the fallback
            // got wrong was the gate. That is why OpportunityReviewService's header could say a
            // Master-type Contract Review "is NOT functionally dead". It is dead now, and that
            // header has been rewritten to say so.
            //
            // The two candidate defaults, and why this one wins — the criterion is WHICH FAILURE,
            // because after the split the fallback is wrong for SOME population either way:
            //
            //   Acquisition_PSA (chosen)  A legacy / Master row still carrying 'Initial Draft' —
            //                             the P3 row migration is scoped BY RECORD TYPE, so a
            //                             Master row is NOT migrated — finds no entry in the
            //                             acquisition map and is REFUSED, loudly, with "There is
            //                             no next step available from the Initial Draft stage."
            //                             Nothing is written. A Master-type row created AFTER this
            //                             pack carries 'Draft' (OpportunityReviewService stamps it
            //                             explicitly) and advances correctly. The gate stays
            //                             DEAL_DRIVER, which grants the disposition buttons to
            //                             nobody new during the deploy window.
            //   Disposition_PSA (rejected) The same legacy Master row WOULD advance — to 'Revised',
            //                             a value no longer on Acquisition_PSA. A WRONG WRITE, not
            //                             a refusal. And the gate would flip to
            //                             DISPOSITION_DRIVER, denying the acquisitions deal driver
            //                             on rows they own while granting disposition drivers
            //                             access to acquisition rows — a real boundary move
            //                             disguised as a default.
            //
            // ⇒ A refusal beats a wrong write, and a conservative gate beats a widened one. Both
            // criteria point at Acquisition_PSA.
            //
            // ✅ AND THE SPLIT FIXES A COMPLAINT THIS FILE HAS CARRIED SINCE 3C. The class header
            // used to record that the Contract Review fallback was QUIETER than NDA__c's or
            // LOI__c's — "the walk works, the toasts are right, nothing looks wrong ... There is no
            // loud symptom to lead anyone to gate T-B here." There is one now: an unmigrated
            // Master-type row refuses on its very first click, naming its own stale status. That is
            // a diagnostic, not a regression.
            Contract_Review__c.SObjectType => new StageConfig(
                'Contract Review', 'Negotiation_Status__c',
                RT_ACQUISITION_PSA,
                new Map<String, StageTypeConfig>{
                    RT_ACQUISITION_PSA => new StageTypeConfig(
                        StageActionGate.DEAL_DRIVER, CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE),
                    RT_DISPOSITION_PSA => new StageTypeConfig(
                        StageActionGate.DISPOSITION_DRIVER, CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE)
                }),
            Underwriting__c.SObjectType => new StageConfig(
                'Underwriting', 'Stage__c',
                new StageTypeConfig(StageActionGate.DEAL_DRIVER, UNDERWRITING_NEXT_STAGE)),
            Construction_Feasibility_Review__c.SObjectType => new StageConfig(
                'Construction Feasibility Review', 'Stage__c',
                new StageTypeConfig(StageActionGate.DEAL_DRIVER, CONSTRUCTION_REVIEW_NEXT_STAGE)),
            Development_Feasibility_Review__c.SObjectType => new StageConfig(
                'Development Feasibility Review', 'Stage__c',
                new StageTypeConfig(StageActionGate.DEAL_DRIVER, DEVELOPMENT_REVIEW_NEXT_STAGE)),
            // ── Transaction__c, added 2026-08-12 ────────────────────────────────────────────
            // ⚠ THE SINGLE-SEQUENCE CONSTRUCTOR IS LOAD-BEARING, NOT SHORTHAND. Transaction__c
            // has NO record types (no objects/Transaction__c/recordTypes/ folder — verified in
            // the org), so byRecordType.size() == 1 and BOTH gateFor() and sequenceKeyFor()
            // short-circuit: hasStageActionAccess costs ZERO extra queries on this object, and no
            // describe is paid. That is the same shape Underwriting__c and the two Feasibility
            // Reviews have always had. Using the five-argument constructor with one entry would
            // compile and behave identically today while implying to the next reader that a
            // record type exists to key on.
            //
            // ⚠ THIS COMMENT USED TO READ "ITS GATE IS THE ONLY MEMBERSHIP-ONLY ONE IN THIS MAP".
            // That stopped being true later the same day: all three gates in this map are now a
            // single FeatureManagement.checkPermission call (see StageActionGate), and this one
            // resolves `Transaction_Stage_Actions`.
            //
            // 🔴 WHAT IS STILL TRUE, AND IS THE REAL DIFFERENCE, IS WHICH LAYER CARRIES THE TOKEN.
            // The two deal permissions sit on directly-assigned LAYER-5 sets; this one sits on the
            // LAYER-4 capability set Transaction_Stage_Actions_Access, which is a member of the
            // DPEG_Transaction_Team group — so this gate is TEAM-WIDE, with no per-user revocation.
            // That is a deliberate, user-made policy decision preserved across the migration, NOT an
            // unfinished gate. TransactionActionPermissionService's header carries the full argument.
            //
            // ⚠ The label 'Transaction' is what the success toast reads ("Transaction moved to
            // Due Diligence.") and is also the NO_NEXT_STEP_HINTS key prefix. This object supplies
            // no hint: every stage without a hop is genuinely terminal, so the default "There is
            // no next step available from the Closed Won stage." is correct wording, unlike
            // Underwriting's approval-owned gap.
            Transaction__c.SObjectType => new StageConfig(
                'Transaction', 'Stage__c',
                new StageTypeConfig(
                    StageActionGate.TRANSACTION_STAGE_ACTIONS, TRANSACTION_NEXT_STAGE))
        };

    /**
     * Moves the record to the single next stage for its current stage.
     *
     * The target is DERIVED from the record's own record-type sequence and can never be supplied by
     * the caller, so this method cannot skip a hop and cannot cross into another record type's
     * value set.
     *
     * @param recordId the NDA / LOI / Contract Review / Underwriting / Construction or Development
     *                 Feasibility Review record to advance (required)
     * @return a user-facing confirmation message, e.g. 'LOI moved to Submitted.'
     * @throws RecordStageAdvanceException when recordId is null, the object is not stage-controlled,
     *         the record has no stage set, the record sits on a record type with no configured
     *         sequence, there is no next step from the current stage, or the write is blocked (the
     *         block's message is surfaced verbatim)
     * @throws System.QueryException when recordId matches no record
     * @example
     * String msg = RecordStageAdvanceService.advance(loiId);
     */
    public static String advance(Id recordId) {
        StageConfig config = configFor(recordId);
        SObject record = load(recordId);

        String currentStage = (String) record.get(config.stageField);
        if (String.isBlank(currentStage)) {
            throw new RecordStageAdvanceException(NO_STAGE_MESSAGE);
        }

        // ⚠ The sequence is chosen from the LOADED record, not from the Id — see the call-order
        // note in the class header. On an object with one sequence this costs nothing at all.
        StageTypeConfig sequence = sequenceFor(config, record);

        String target = sequence.nextStage.get(currentStage);
        if (target == null) {
            throw new RecordStageAdvanceException(noNextStepMessage(config, currentStage));
        }
        return setStage(record, config, target);
    }

    /**
     * Moves the record to an EXPLICIT stage, which must be on that object's allow-list.
     *
     * Added 2026-08-05 for the LOI 'Sent' branch — a broker either counters or accepts, so the deal
     * driver needs two named buttons where advance() can only derive one. Extended 2026-08-09 for
     * the disposition NDA's 'Declined' off-ramp, and again at the Tranche 3B close-out for the
     * DISPOSITION LOI'S NEGOTIATION LOOP — the sharpest case of the three, because its back-edge
     * ('Counter Received from Buyer' -> 'Countered by DPEG') is not merely inconvenient to derive,
     * it is PROVABLY inexpressible in a Map<String, String> that already maps that key forward. It
     * mirrors StageAdvanceService.advanceTo, including the reason that method exists at all.
     *
     * 🔴 THE ALLOW-LIST IS THE WHOLE POINT AND IS PER RECORD TYPE. Without it, any holder of
     * controller access could write ANY stage on ANY of seven objects, skipping every hop and every
     * gate — the exact hole StageAdvanceService.ALLOWED_EXPLICIT_TARGETS was created to close. Held
     * at OBJECT level it would be only half closed: 'Declined' belongs to the disposition NDA, but
     * Apex DML does not enforce record-type picklist restrictions, so an object-level list would
     * write it onto an acquisition NDA just as happily. Adding a branch action means adding its
     * stage to that RECORD TYPE's set; do NOT add derivable forward hops, which belong to advance()
     * and therefore cannot skip a step.
     *
     * ⚠ THE ALLOW-LIST CHECK IS AFTER load(), NOT BEFORE IT. It has to be — the list is a property
     * of the record type, and the record type is a property of the row. See the class header for
     * the one visible consequence (a non-existent Id now raises QueryException here).
     *
     * The rejection message deliberately does NOT echo the supplied value back: a legitimate caller
     * can never reach that branch (each bundle passes a hardcoded constant), so the only way in is a
     * hand-crafted call, and reflecting attacker-supplied text into a toast has no upside. Same
     * wording choice as StageAdvanceService.
     *
     * @param recordId the stage-controlled record to move (required)
     * @param target   the destination stage; must be on this RECORD TYPE's allow-list
     * @return a user-facing confirmation message, e.g. 'LOI moved to Signed.'
     * @throws RecordStageAdvanceException when recordId is null, target is blank, target is not an
     *         allowed explicit target for this record's record type, the object is not
     *         stage-controlled, the record sits on a record type with no configured sequence, or
     *         the write is blocked (the block's message is surfaced verbatim)
     * @throws System.QueryException when recordId matches no record
     * @example
     * String msg = RecordStageAdvanceService.advanceTo(loiId, 'Signed');
     */
    public static String advanceTo(Id recordId, String target) {
        if (String.isBlank(target)) {
            throw new RecordStageAdvanceException('No target stage was provided.');
        }
        StageConfig config = configFor(recordId);
        SObject record = load(recordId);
        StageTypeConfig sequence = sequenceFor(config, record);
        if (!sequence.explicitTargets.contains(target)) {
            throw new RecordStageAdvanceException('That stage is not available from this action.');
        }
        return setStage(record, config, target);
    }

    /**
     * Whether the running user may drive the stage action on this record. The UX gate behind
     * RecordStageAdvanceController.hasStageActionAccess.
     *
     * DISPATCHES to the RECORD TYPE's configured gate; it does NOT merge gates. THREE of the seven
     * objects answer wholly to DEAL_DRIVER (`Underwriting__c` and the two Feasibility Reviews);
     * three — `NDA__c`, `LOI__c` and, since Tranche 3C, `Contract_Review__c` — answer to
     * DEAL_DRIVER on their `Acquisition_*` type and DISPOSITION_DRIVER on their `Disposition_*`
     * type; and `Transaction__c` (2026-08-12) answers wholly to TRANSACTION_STAGE_ACTIONS.
     *
     * ⚠ That last clause used to end "…, the one MEMBERSHIP-ONLY gate in the enum" and no longer
     * does: since the 2026-08-12 custom-permission migration all three gates are the same shape, and
     * the surviving asymmetry is which permission-set LAYER carries each token (see StageActionGate).
     * Dispatch is unaffected either way — this method never knew a gate's mechanism, only its name.
     *
     * ⚠ IT NOW LOADS THE RECORD — but only when it has to. Since 2026-08-09 the gate is a property
     * of the record type, and the record type is a property of the row, so an object with more
     * than one configured sequence costs ONE extra SOQL here (a `cacheable=true` path invoked once
     * per record view — the design accepts that). An object with a single sequence short-circuits
     * and still costs ZERO queries, the same optimisation sequenceKeyFor already makes.
     *
     * ⚠ THE GATE ITSELF GOT CHEAPER ON 2026-08-12 AND THE ROW LOAD DID NOT. Retiring the
     * `*_Driver__c` flags took each gate from 2 queries to 0 (holder) or 1 (non-holder), so this
     * method now costs, per record view: 1 for a single-sequence object's non-holder and 0 for its
     * holder; 2 and 1 respectively for a multi-record-type object, where the row load survives
     * untouched because it answers a different question — WHICH gate applies, not whether the user
     * passes it. Anyone hoping the migration removed the load should read `gateFor`.
     *
     * ⚠ TWO CONSEQUENCES, BOTH SMALL AND BOTH REAL:
     *   - `advance()` on an NDA now costs 2 SOQL for the pair (this check, then the service's own
     *     load) rather than 1, because the controller asserts BEFORE calling advance and each call
     *     is independent. Acceptable on a per-click singleton; sharing the row between them would
     *     mean changing the controller's shape for one query.
     *   - A NON-EXISTENT NDA Id now raises System.QueryException here where it previously returned
     *     the object-level answer. The controller maps that to its fixed generic message, so the
     *     gate still fails CLOSED and no user-visible wording changes.
     *
     * @param recordId the record whose object AND record type decide which gate applies (required)
     * @return true when the running user passes that record type's gate
     * @throws RecordStageAdvanceException when recordId is null, the object is not
     *         stage-controlled, or the record sits on a record type with no configured sequence
     * @throws System.QueryException when recordId matches no record, or when the permission
     *         machinery itself fails unexpectedly. Deliberately NOT swallowed — a fault must not
     *         read as a denial. The controller masks and logs it; the LWC treats a thrown check
     *         exactly like false, so the gate still fails CLOSED end to end.
     * @example
     * if (!RecordStageAdvanceService.hasStageActionAccess(loiId)) { return; }
     */
    public static Boolean hasStageActionAccess(Id recordId) {
        return passesGate(gateFor(configFor(recordId), recordId));
    }

    /**
     * The gate governing THIS record.
     *
     * The `size() == 1` short-circuit is a correctness statement as much as an optimisation: an
     * object with one configured sequence has one gate BY CONSTRUCTION, so loading the row could
     * not change the answer — and paying a query per record view on the FOUR objects that will
     * never need it (the three record-type-free acquisitions children plus Transaction__c) would
     * be a real cost for no information.
     */
    private static StageActionGate gateFor(StageConfig config, Id recordId) {
        if (config.byRecordType.size() == 1) {
            return config.byRecordType.get(config.defaultTypeKey).gate;
        }
        return sequenceFor(config, load(recordId)).gate;
    }

    /**
     * Server-side guard. Called as the first statement of every @AuraEnabled entry point so the
     * declarative Dynamic Actions visibility rule — a UX affordance only — cannot be bypassed by
     * invoking the @AuraEnabled method directly.
     *
     * @param recordId the record whose object decides which gate applies (required)
     * @throws AccessDeniedException carrying the shared denial wording when the user lacks access
     * @throws RecordStageAdvanceException when recordId is null or the object is not stage-controlled
     * @throws System.QueryException when the permission lookup itself fails unexpectedly
     * @example
     * RecordStageAdvanceService.assertStageActionAccess(recordId);
     */
    public static void assertStageActionAccess(Id recordId) {
        if (hasStageActionAccess(recordId)) {
            return;
        }
        // One wording for the client gate, the server assert, and both stage features — the user
        // must never see two phrasings for one condition.
        throw new AccessDeniedException(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE);
    }

    /**
     * Whether an object is stage-controlled by this service. Lets a caller ask without provoking an
     * exception.
     *
     * @param recordId any record Id; null-safe
     * @return true when the record's object has a stage map here
     */
    public static Boolean isSupported(Id recordId) {
        return recordId != null && CONFIG_BY_TYPE.containsKey(recordId.getSObjectType());
    }

    private static StageConfig configFor(Id recordId) {
        if (recordId == null) {
            throw new RecordStageAdvanceException(NO_RECORD_MESSAGE);
        }
        StageConfig config = CONFIG_BY_TYPE.get(recordId.getSObjectType());
        if (config == null) {
            throw new RecordStageAdvanceException(UNSUPPORTED_OBJECT_MESSAGE);
        }
        return config;
    }

    /**
     * The stage sequence that governs THIS record — chosen by record type, which is why it takes a
     * loaded record and not an Id.
     *
     * FALLBACK RULES, in order, each for a different reason:
     *   1. The object has exactly ONE sequence  -> that sequence, with no describe at all. FOUR of
     *      the seven objects since Transaction__c joined 2026-08-12, and the whole reason
     *      record-type awareness is free for them. ⚠ "One sequence" means one StageTypeConfig, NOT
     *      one map: Contract_Review__c has two configs sharing one map and correctly does NOT take
     *      this branch, because its two configs carry different GATES.
     *   2. RecordTypeId is null or unqueried    -> defaultTypeKey (the ACQUISITION sequence). This
     *      is the deploy window: before T1 the field does not exist, and between T1 and the row
     *      migration every live row is on Master.
     *   3. The record type is Master            -> defaultTypeKey, same window, same reason.
     *   4. A real, NAMED record type with no configured sequence -> REFUSED. Never defaulted; see
     *      the class header for why a silent fallback here is unsafe rather than merely untidy.
     */
    private static StageTypeConfig sequenceFor(StageConfig config, SObject record) {
        return config.byRecordType.get(sequenceKeyFor(config, record));
    }

    private static String sequenceKeyFor(StageConfig config, SObject record) {
        if (config.byRecordType.size() == 1) {
            return config.defaultTypeKey;
        }
        Id recordTypeId = recordTypeIdOf(record);
        if (recordTypeId == null) {
            return config.defaultTypeKey;
        }
        Schema.RecordTypeInfo info = record.getSObjectType()
            .getDescribe()
            .getRecordTypeInfosById()
            .get(recordTypeId);
        if (info == null || info.isMaster()) {
            return config.defaultTypeKey;
        }
        String developerName = info.getDeveloperName();
        if (!config.byRecordType.containsKey(developerName)) {
            throw new RecordStageAdvanceException(UNSUPPORTED_RECORD_TYPE_MESSAGE);
        }
        return developerName;
    }

    /**
     * The loaded record's RecordTypeId, or null when the object carries no record types, when the
     * selector did not select the field, or when the row genuinely has none.
     *
     * ⚠ getPopulatedFieldsAsMap() rather than record.get('RecordTypeId') because it NEVER THROWS.
     * MEASURED on usman-dpeg 2026-08-09, both halves:
     *   - get('RecordTypeId') on a record whose SELECT omitted it -> System.SObjectException;
     *   - get('RecordTypeId') on a record whose SELECT included it, value null -> null.
     * FOUR of the seven selectors here deliberately do not select RecordTypeId, so the direct read
     * would turn "this object has no record types" into a runtime failure for them.
     *
     * ⚠ ALSO MEASURED, and it is the reason this returns null so often: a field that WAS queried
     * but is NULL is DROPPED from getPopulatedFieldsAsMap() entirely —
     * `SELECT Id, Status__c, RecordTypeId` on a Master-type row yields the key set {Id, Status__c}.
     * So this method cannot distinguish "not selected" from "selected and empty", and it does not
     * need to: both mean "no record type to key on", and both must take the default sequence. A
     * caller wanting to assert the field was actually SELECTED must use get() and expect the
     * SObjectException — see NdaSelectorTest.
     *
     * ⚠ The key comparison is case-INSENSITIVE deliberately. Apex Map<String, Object> keys are
     * case-SENSITIVE, while the casing of that map's keys is chosen by the platform. A mismatch
     * would return null and route every record to the fallback sequence — a silent degradation
     * whose only symptom is "the disposition NDA behaves like an acquisition one". The map holds a
     * handful of entries, so the scan costs nothing.
     */
    private static Id recordTypeIdOf(SObject record) {
        Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        for (String fieldName : populated.keySet()) {
            if (RECORD_TYPE_ID_FIELD.equalsIgnoreCase(fieldName)) {
                return (Id) populated.get(fieldName);
            }
        }
        return null;
    }

    /**
     * Loads the record through its own selector.
     *
     * Deliberately a chain of SObjectType TOKEN comparisons rather than an Apex `switch on`: Apex's
     * switch accepts a String or an enum but not a Schema.SObjectType, so a switch here would have
     * to key on the object's API NAME as a string literal — trading compile-checking for seven
     * stringly-typed keys, for no benefit. Every branch is a static, fully-literal, WITH USER_MODE
     * selector call: zero dynamic SOQL and zero string-built queries.
     *
     * ⚠ The local is named `objectType`, not `recordType`. Since 2026-08-09 this class also deals
     * in RECORD types, and a Schema.SObjectType called `recordType` is now actively misleading.
     *
     * ⚠ A selector whose object is record-type-aware MUST select RecordTypeId — today NdaSelector
     * (3A), LoiSelector (3B) and ContractReviewSelector (3C). Omitting it does not fail; it
     * degrades to the default sequence, silently. All three selector methods carry a DO-NOT-NARROW
     * note saying so. ⚠ ContractReviewSelector's is the easiest to talk yourself out of, because
     * that object's two record types share a stage sequence — but they do NOT share a gate, and the
     * gate is resolved from the same field.
     *
     * FETCH-FOR-USE: each selector method throws System.QueryException on a miss (repo contract).
     */
    private static SObject load(Id recordId) {
        Schema.SObjectType objectType = recordId.getSObjectType();
        if (objectType == NDA__c.SObjectType) {
            return NdaSelector.selectStageRequiredById(recordId);
        }
        if (objectType == LOI__c.SObjectType) {
            return LoiSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Underwriting__c.SObjectType) {
            return UnderwritingSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Construction_Feasibility_Review__c.SObjectType) {
            return ConstructionFeasibilityReviewSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Development_Feasibility_Review__c.SObjectType) {
            return DevelopmentFeasibilityReviewSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Contract_Review__c.SObjectType) {
            return ContractReviewSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Transaction__c.SObjectType) {
            return TransactionSelector.selectStageRequiredById(recordId);
        }
        // Unreachable in practice — configFor() already rejected every unsupported type before this
        // is called. Kept so a new CONFIG_BY_TYPE entry without a matching selector branch fails
        // loudly and immediately instead of returning null.
        throw new RecordStageAdvanceException(UNSUPPORTED_OBJECT_MESSAGE);
    }

    /**
     * Asks the record type's configured gate. A gate with no branch here DENIES — an unwired gate
     * must never read as a grant, which is exactly why DISPOSITION_DRIVER was not declared until
     * the day its permission set and this branch landed together.
     *
     * ⚠ SINCE 2026-08-12 ALL THREE BRANCHES ARE THE SAME SHAPE — one custom-permission check plus a
     * "Modify All Data" bypass, each memoized in its own service. That does NOT make the switch
     * collapsible into a single call with a permission-name parameter: the three services are three
     * separate authorization boundaries with three separate caches, and flattening them would let a
     * future change to one silently apply to all three. The dispatch IS the boundary.
     *
     * ⚠ COST: every branch is now 0 SOQL for a holder and 1 for everyone else (it was 2 for the
     * first two branches before the migration). That is ON TOP of the row load `gateFor` performs
     * for a multi-record-type object, which is unchanged.
     */
    private static Boolean passesGate(StageActionGate gate) {
        Boolean allowed = false;
        switch on gate {
            when DEAL_DRIVER {
                allowed = OpportunityActionPermissionService.hasDealActionAccess();
            }
            when DISPOSITION_DRIVER {
                allowed = DispositionActionPermissionService.hasDispositionActionAccess();
            }
            when TRANSACTION_STAGE_ACTIONS {
                // ⚠ Same MECHANISM as the two branches above since 2026-08-12, but a different
                // POLICY: its permission rides on a layer-4 capability set inside
                // DPEG_Transaction_Team, so this gate is team-wide and has no per-user revocation.
                // That is preserved from the membership check it replaced, not a side effect of it.
                // See StageActionGate and TransactionActionPermissionService's class header.
                allowed = TransactionActionPermissionService.hasTransactionActionAccess();
            }
            when else {
                allowed = false;
            }
        }
        return allowed;
    }

    private static String noNextStepMessage(StageConfig config, String currentStage) {
        // ⚠ Do NOT name this local `hint` — that identifier is RESERVED in Apex and fails to
        // compile with "Identifier name is reserved: hint" (same trap as `bulk`).
        String specificMessage = NO_NEXT_STEP_HINTS.get(config.label + '|' + currentStage);
        if (String.isNotBlank(specificMessage)) {
            return specificMessage;
        }
        return 'There is no next step available from the ' + currentStage + ' stage.';
    }

    private static String setStage(SObject record, StageConfig config, String target) {
        try {
            record.put(config.stageField, target);
            update record;
            return config.label + ' moved to ' + target + '.';
        } catch (DmlException e) {
            // A validation rule, a required-field rule, or a picklist restriction. Surfacing the
            // platform message verbatim is the POINT of routing these writes through Apex — on the
            // LDS route the rule text lands in body.output.errors[] where the shared guard never
            // reads it, and the rule would ship invisible (design doc §5).
            //
            // ⚠ The getNumDml() guard is load-bearing, not defensive noise. A DmlException with NO
            // row detail is a real shape (MIXED_DML_OPERATION, LIMIT_EXCEEDED); on those,
            // getDmlMessage(0) itself throws, which would escape this catch, land in the
            // controller's GENERIC clause and mask a genuine save block as "refresh the page".
            // StageAdvanceService.setStage calls getDmlMessage(0) unguarded — that is a latent
            // difference, not an oversight here.
            throw new RecordStageAdvanceException(
                e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        }
    }
}
