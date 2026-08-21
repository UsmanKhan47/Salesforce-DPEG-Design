/**
 * Everything `c/dispositionLogOfferModal` needs to render the Log Offer dialog: the BROKER the offer
 * is attributed to, resolved and never typed. Added 2026-08-21 with the in-place Log Offer modal
 * (`agent-output/offer-form-and-stage-retirement.md` §A, resolution Option 3); the buyer half was
 * REMOVED later the same day.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE BUYER PICKER IS GONE. THE DIALOG NOW HAS EXACTLY ONE PARTY, AND IT IS THE BROKER.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * User decision, 2026-08-21: *"we don't need buyer information, we just need broker contact for
 * disposition offers and NDA… everything must be linked with broker contact as he is the only
 * person that DPEG will be communicating"*. Buyers sit behind the appointed listing broker and are
 * not tracked, so `BuyerOption`, the `buyers` list, the de-duplication and the
 * `NdaSelector.selectSignedBuyerNdasByDispositionId` read were all deleted rather than left
 * unreferenced.
 *
 * ⚠ THE ARGUMENT THAT USED TO LIVE HERE — "one buyer per disposition would be wrong because
 * `DispositionBuyerTimelineService` joins each buyer's NDA to THAT BUYER'S first offer" — IS NOW
 * MOOT AND MUST NOT BE RE-DERIVED FROM IT. That join was deleted the same day, for the same reason.
 * If buyer identity ever returns, it returns as a NEW decision with a NEW justification.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 🔴 SHIP-BLOCKER, NOT A NOTE: `Buyer_Required_On_Offer` IS **ACTIVE** IN `usman-dpeg`.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Measured via the Tooling API on 2026-08-21: six validation rules are active on
 * `Disposition_Offer__c`, and one of them is `Buyer_Required_On_Offer`, whose formula is
 * `ISBLANK(Buyer_Name__c)` with NO `ISNEW` / `ISCHANGED` guard. `Buyer_Name__c` is derived from
 * `Buyer__c` by `DispositionOfferBuyerStampService` in before-save — so with the picker gone,
 * nothing sets `Buyer__c`, nothing derives `Buyer_Name__c`, and **EVERY save from the Log Offer
 * dialog is refused, permanently, for every user.**
 * 🔴 THE FIX IS DECLARATIVE AND IS NOT IN THIS LAYER: that validation rule must be deactivated (or
 * repointed at `Broker__c`) by whoever owns `objects/**`. Deploying this class without that change
 * ships a dialog that cannot save. This paragraph exists so the failure is diagnosed in one minute
 * instead of one afternoon — the platform's refusal names `Buyer_Name__c`, a field the form does
 * not show and no longer has any way to populate.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE BROKER IS RESOLVED FROM A DIFFERENT SOURCE PER RECORD TYPE, AND NEITHER IS A TEXT PARSE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 *   ON-MARKET   `BOV_Submission__c.Broker__c` on the submission whose `Submission_Status__c` is
 *               `Selected`. The firm won the listing by winning the BOV.
 *   OFF-MARKET  `Disposition__c.Broker__c` — a real Contact lookup on the parent, added 2026-08-20,
 *               *"the field the Broker Selection approval gate tests"*. Zero extra query.
 *
 * 🔴 `Disposition__c.Selected_Broker__c` IS NOT READ, IS NOT SELECTED, AND MUST NEVER BE PARSED.
 * `DispositionBrokerStampService`'s header states it as a standing rule: the field reads `Firm` on
 * on-market rows and `Person - Firm` on off-market ones, so *"a parser would work on whichever path
 * its author tested and fail silently on the other"*. It is the shortcut this class most obviously
 * invites (one field, both paths, one fewer query) and it is the wrong turn.
 * `DispositionSelector.selectBrokerContextById` deliberately does not even select it.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 A NULL BROKER IS STILL AN ACCEPTED **OUTCOME OF THIS CLASS** — BUT IT IS NO LONGER AN
 *    ACCEPTED STATE FOR AN OFFER. THE REFUSAL MOVED TO THE MODAL, ON PURPOSE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * This class still answers `brokerId = null` rather than throwing, because "no broker appointed
 * yet" is a real, readable state of a disposition and the dialog has to be able to EXPLAIN it. What
 * changed is what the modal does with that answer: it now renders an explained refusal panel with
 * no form and no Save button, where it used to render the form with an empty read-only field.
 *
 * ⚠ THE REASONING, STATED SO IT CAN BE ARGUED WITH RATHER THAN INHERITED: with the buyer removed,
 * `Broker__c` is the ONLY party on a `Disposition_Offer__c`. An offer naming nobody cannot be
 * attributed, cannot be told apart from another offer on the same sale, and is what
 * `DispositionApprovalService.selectOffer` would be choosing between. The old design (§A.3)
 * accepted a null broker precisely BECAUSE the buyer identified the offer; that premise is gone.
 * 🔴 IT HAS A REAL COST AND THE COST IS REPORTED, NOT HIDDEN: an offer that genuinely arrives
 * before the broker is appointed can no longer be logged from this dialog. The remedy is on another
 * screen (the BOV comparison matrix, or the Broker Selection stage) and the panel names it.
 *
 * ⚠ MEASURED IN `usman-dpeg` 2026-08-21: the org's ONE disposition (DISP-0011, On_Market, Active
 * Listing) has `Disposition__c.Broker__c = null` and a Selected BOV-0015 carrying
 * `Broker__c = Derek Simmons` — so the on-market branch resolves and the off-market branch has no
 * live row to exercise at all.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 NEITHER BROKER READ IS CAUGHT ANY MORE. BOTH PROPAGATE. THAT IS A DELIBERATE REVERSAL.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Until 2026-08-21 both reads sat inside `catch (System.QueryException)` blocks that degraded to
 * "no broker resolved", on the argument that *"an FLS gap on `BOV_Submission__c.Broker__c` (which
 * `DPEG_Admin_Access` genuinely lacks — measured) must not take down a dialog whose central control
 * is the buyer picker"*. **The buyer picker was the thing that argument rested on, and it is gone.**
 *
 * Keeping those catches now would invert the failure: a persona who cannot READ the broker would be
 * told "no broker is appointed on this sale — go appoint one", about a sale that has one. That is
 * the wrong-answer-not-an-error shape this repo has paid for repeatedly, and it is strictly worse
 * than an error naming a provisioning gap. So a `QueryException` from either read propagates to
 * `DispositionOfferFormController`, which converts it to an authored ACCESS message.
 * ⚠ SECOND-ORDER CONSEQUENCE, AND IT IS THE ONE THAT WOULD HAVE BITTEN SILENTLY: with the NDA read
 * deleted, those two catches would have made this method incapable of throwing AT ALL — leaving the
 * controller's single `catch` permanently unreachable, dragging that class under the 75% per-class
 * coverage threshold, and rolling a deploy back with every error counter reading zero (this repo
 * has a measured incident of exactly that). Removing them restores reachability as well as truth.
 * 🔴 THE FIX FOR SUCH AN ERROR IS A PERMISSION SET, NEVER `SYSTEM_MODE` — ARCHITECTURE.md §2.
 * `DPEG_Admin_Access` does not grant `BOV_Submission__c.Broker__c` (measured 2026-08-21); if that
 * persona needs the Log Offer dialog, grant the field.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS IS A READ SERVICE. DO NOT ADD A WRITE PATH.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The record is created by `lightning-record-edit-form`, which enforces CRUD/FLS for the running
 * user and surfaces every validation rule's AUTHORED message through `<lightning-messages>`; an
 * Apex insert would lose that attribution and duplicate a platform capability.
 *
 * ── LAYERING / BUDGET / BULK ──────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). ZERO inline SOQL — both reads go to selectors
 * (`DispositionSelector`, `BovSubmissionSelector`). ZERO DML at any input.
 *
 * BUDGET: **AT MOST 2 SOQL, EXACTLY 0 DML, PER CALL** (it was 3 until the NDA read was deleted).
 * Off-market costs 1 — the BOV read is skipped entirely; a null Id costs 0. That ceiling is
 * asserted in `DispositionOfferFormServiceTest` rather than described, because the failure mode of
 * a third query added later is invisible on a single-record screen.
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE DOES NOT APPLY, AND THE REASON IS
 * STRUCTURAL RATHER THAN CONVENIENT. That rule's own exemption is for methods that are
 * "structurally single-record-per-transaction": this one takes a SINGLE `Id`, is invoked exactly
 * once per modal open by a `@wire`, has no trigger, no batch and no collection parameter to bulk.
 * There is no loop that a 251st record would force a second pass through, so a 251-record test would
 * exercise no additional code path while proving nothing — the exact anti-pattern that exemption
 * exists to prevent. ⚠ IF A CALLER EVER PASSES A COLLECTION, THIS EXEMPTION LAPSES — re-read the
 * rule, do not extend the argument.
 *
 * ── SHARING ───────────────────────────────────────────────────────────────────────────────
 * `with sharing`, and every selector read is `WITH USER_MODE`. A BOV submission the running user
 * cannot see is simply absent, which correctly resolves to "no broker appointed" rather than
 * offering a value whose save would then be refused.
 *
 * @see force-app/main/default/classes/DispositionOfferFormController.cls (the only caller)
 * @see force-app/main/default/classes/DispositionOfferBuyerStampService.cls (now INERT — it derives
 *      `Buyer_Name__c` from `Buyer__c`, is change-keyed, and nothing sets `Buyer__c` from this
 *      dialog any more. Deliberately NOT deleted: a separate retirement wave owns the field.)
 * @see agent-output/offer-form-and-stage-retirement.md (§A.3 broker source)
 */
public with sharing class DispositionOfferFormService {

    /**
     * Shown beside the read-only broker so the analyst can see WHY that name is there, and reused as
     * the REMEDY line when no broker resolves at all. Two record types, two sources, two different
     * screens — a bare empty field would send an on-market user to the wrong one.
     */
    @TestVisible
    private static final String SOURCE_ON_MARKET = 'From the selected BOV submission';

    /** @see SOURCE_ON_MARKET */
    @TestVisible
    private static final String SOURCE_OFF_MARKET = 'From the broker picked on this disposition';

    /**
     * The whole dialog context in one round trip.
     *
     * ⚠ IT IS STILL ONE `@AuraEnabled` RETURN RATHER THAN THREE CACHEABLE METHODS even though it now
     * carries one subject instead of two: the modal cannot render a half-answer (the record type
     * decides the wording of the refusal panel as well as the source line), and three wires would be
     * three cache entries that can disagree.
     */
    public class OfferFormContext {
        /**
         * The resolved broker Contact Id, or NULL when none is appointed yet.
         *
         * 🔴 NULL IS NOW THE MODAL'S REFUSAL CONDITION, NOT MERELY AN EMPTY FIELD. See the class
         * header: with the buyer gone, this is the only party on the offer.
         */
        @AuraEnabled
        public String brokerId;

        /** The broker's display name, or '' when unresolved. NEVER null — see `getFormContext`. */
        @AuraEnabled
        public String brokerName;

        /**
         * Why that broker: `SOURCE_ON_MARKET` or `SOURCE_OFF_MARKET`. NEVER null. Rendered as help
         * text under the read-only field.
         */
        @AuraEnabled
        public String brokerSource;

        /**
         * TRUE when the parent is on the `On_Market` record type. The modal uses it only to word
         * the no-broker refusal ("appoint a broker on the BOV matrix" vs "pick a broker on this
         * disposition") — two different screens, so one generic sentence would misdirect half the
         * users.
         */
        @AuraEnabled
        public Boolean isOnMarket;
    }

    /**
     * Resolves the broker for one Disposition.
     *
     * ── THE OUTCOMES, AND WHY EACH IS THE SAFE DIRECTION ──────────────────────────────────
     *
     *   dispositionId NULL          -> a fully-populated, EMPTY context. Never null, never a throw:
     *                                  the modal's `@wire` fires before `dispositionId` is set on a
     *                                  slow first render, and a throw there would flash an error
     *                                  toast on a dialog that is about to work.
     *   No visible Disposition      -> same empty context, `isOnMarket = true`. The record-type
     *                                  fallback is `DispositionDomain.recordTypeNameOf`'s own
     *                                  (`On_Market` for Master/unset), reused rather than
     *                                  re-derived, so a Master-record-type row cannot answer
     *                                  differently here than it does in `DispositionApprovalService`.
     *   No broker appointed         -> `brokerId` null, `brokerName` ''. 🔴 NOT AN ERROR AND NOT A
     *                                  THROW — the modal explains it and refuses the save. See the
     *                                  class header for why the refusal moved there rather than
     *                                  living here.
     *   EITHER broker read THROWS   -> propagates. Neither is caught any more. A broker the running
     *                                  user cannot READ must not be reported as a broker that does
     *                                  not EXIST — see the class header.
     *
     * @param dispositionId The Disposition__c the Log Offer button was clicked on; null-safe.
     * @return A fully-populated context. NEVER null, and no field on it is ever null except
     *         `brokerId`.
     * @throws System.QueryException when the running user cannot read `Disposition__c.Broker__c`,
     *         `BOV_Submission__c.Broker__c` / `Submission_Status__c`, or `Contact`. The controller
     *         converts it to an authored `AuraHandledException` naming a permission problem.
     * @example
     * DispositionOfferFormService.OfferFormContext ctx =
     *     DispositionOfferFormService.getFormContext(dispositionId);
     */
    public static OfferFormContext getFormContext(Id dispositionId) {
        OfferFormContext context = new OfferFormContext();
        context.brokerId = null;
        context.brokerName = '';
        context.brokerSource = '';
        context.isOnMarket = true;

        if (dispositionId == null) {
            return context;
        }

        // ── 1. The parent: record type (which decides the broker source) and the off-market broker.
        // 🔴 NOT WRAPPED IN A TRY. Until 2026-08-21 it was, and the class header records why the
        // catch was removed rather than kept: the broker IS the dialog now, so "unreadable" must not
        // be reported to the user as "not appointed".
        Disposition__c parent = DispositionSelector.selectBrokerContextById(dispositionId);

        // `recordTypeNameOf` is null-safe and answers On_Market for a null/Master record type, so an
        // absent parent lands on the same branch a Master-record-type row does. ONE helper, one
        // answer — see DispositionDomain, which exists because two copies of this test disagreed.
        Boolean isOnMarket =
            !DispositionDomain.RT_OFF_MARKET.equals(DispositionDomain.recordTypeNameOf(parent));
        context.isOnMarket = isOnMarket;
        context.brokerSource = isOnMarket ? SOURCE_ON_MARKET : SOURCE_OFF_MARKET;

        // ── 2. The broker. Two sources, and the ON-MARKET one costs a second query — which is why it
        // is inside the branch rather than read unconditionally.
        if (isOnMarket) {
            for (BOV_Submission__c submission
                    : BovSubmissionSelector.selectSelectedBrokerByDispositionId(dispositionId)) {
                // ⚠ A `Selected` row can carry a NULL `Broker__c` — the lookup post-dates the object
                // and legacy submissions have only `Broker_Firm__c`. Keep looking rather than
                // accepting the first row, so a legacy row does not mask a real one.
                if (submission.Broker__c != null) {
                    context.brokerId = submission.Broker__c;
                    context.brokerName = resolveContactName(submission.Broker__r);
                    break;
                }
            }
        } else if (parent != null && parent.Broker__c != null) {
            context.brokerId = parent.Broker__c;
            context.brokerName = resolveContactName(parent.Broker__r);
        }

        return context;
    }

    /**
     * `contact.Name` when the related sObject came back, '' when it did not.
     *
     * ⚠ ALWAYS A STRING, NEVER NULL — every consumer of this value crosses the `@AuraEnabled`
     * boundary into an LWC, where a null bound to an element attribute renders the literal text
     * "undefined" (measured in this repo, `lwc-attribute-stringification`).
     * ⚠ `Broker__r` CAN BE NULL WHILE `Broker__c` IS NOT: `USER_MODE` returns the Id but not the
     * related sObject when the running user cannot see that Contact under SHARING (mode lifts FLS,
     * never sharing). That is a REACHABLE state, not a defensive nicety — and it is why the modal
     * gates its form on `brokerId` rather than on `brokerName`.
     *
     * @param contact The traversed Contact, or null.
     * @return The name, or ''.
     */
    private static String resolveContactName(Contact contact) {
        return (contact == null || contact.Name == null) ? '' : contact.Name;
    }
}
