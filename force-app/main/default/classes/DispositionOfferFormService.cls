/**
 * Everything `c/dispositionLogOfferModal` needs to render the Log Offer dialog: the BROKER the
 * offer should be attributed to (resolved, never typed) and the BUYERS it may be attributed to (the
 * signed buyer-role NDAs on this sale). Added 2026-08-21 with the in-place Log Offer modal
 * (`agent-output/offer-form-and-stage-retirement.md` §A, resolution Option 3).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY A PICKER EXISTS AT ALL — THE "STAMP ONE BUYER PER DISPOSITION" DESIGN WAS REJECTED
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The obvious simplification — resolve ONE buyer for the disposition and stamp it onto every offer,
 * hiding the field — is CONFLICT FLAG #1 of the design document, and it is wrong in a way nothing on
 * the page contradicts. `DispositionBuyerTimelineService` joins each buyer's NDA to THAT BUYER'S
 * first offer on a Contact Id at both ends (`Disposition_Offer__c.Buyer__c == NDA__c.Buyer__c`), so
 * one disposition-scoped buyer on every offer would:
 *   1. show buyer 1 a first-offer date derived from offers buyers 2 and 3 made;
 *   2. leave buyers 2 and 3 with a permanent em dash — the exact "legacy row" shape that service's
 *      header says can never be matched to an offer;
 *   3. render the SAME NAME ON EVERY ROW of `c/dispositionOffer`'s competitive bid table;
 *   4. hand `DispositionApprovalService.selectOffer` a set of offers that all name one party, when
 *      "buyer identity is what selectOffer is ultimately choosing between".
 * A multi-buyer sale is the NORMAL shape here — it is what `c/dispositionCallForOffers` runs, what
 * `Offer Selection` is a stage for and what `DispositionOfferSelectionGuardService` arbitrates. So
 * the analyst still never TYPES a buyer; they pick from the two or three names the deal already has.
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
 * ⚠ A NULL BROKER IS AN ACCEPTED OUTCOME ON BOTH PATHS, NOT A FAILURE. On-market, `Broker__c` only
 * exists once `Broker_Finalize_Approval` has approved a submission; off-market, it is set at
 * `Broker Selection`. An offer logged before that resolves to a null broker and NOTHING BACKFILLS IT
 * LATER. That was accepted in the design (§A.3) rather than solved, because offers do not normally
 * exist that early — it is documented here so it is not discovered in UAT and mistaken for a defect.
 * ⚠ MEASURED IN `usman-dpeg` 2026-08-21: the org's ONE disposition (DISP-0011, On_Market, Active
 * Listing) has `Disposition__c.Broker__c = null` and a Selected BOV-0015 carrying
 * `Broker__c = Derek Simmons` — so the on-market branch resolves and the off-market branch has no
 * live row to exercise at all.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ THE BUYER LOOKUP IS ALL THIS FEATURE HAS TO SET — `Buyer_Name__c` FALLS OUT FOR FREE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `DispositionOfferBuyerStampService.stampBuyerName` ALREADY derives `Buyer_Name__c` from `Buyer__c`
 * in before-insert and before-update, and a before trigger runs BEFORE validation — so setting the
 * lookup satisfies `Buyer_Required_On_Offer` (`ISBLANK(Buyer_Name__c)`) in the same save. This class
 * therefore writes NOTHING and must not: a modal that also sent `Buyer_Name__c` would be handing the
 * user a value the stamp overwrites inside the same transaction.
 * 🔴 DO NOT ADD A WRITE PATH HERE. This is a READ service. The record is created by
 * `lightning-record-edit-form`, which enforces CRUD/FLS for the running user and surfaces every
 * validation rule's AUTHORED message through `<lightning-messages>`; an Apex insert would lose that
 * attribution and duplicate a platform capability.
 *
 * ── LAYERING / BUDGET / BULK ──────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). ZERO inline SOQL — all three reads go to selectors
 * (`DispositionSelector`, `NdaSelector`, `BovSubmissionSelector`). ZERO DML at any input.
 *
 * BUDGET: **AT MOST 3 SOQL, EXACTLY 0 DML, PER CALL.** Off-market costs 2 (the BOV read is skipped
 * entirely); a null or unreadable disposition costs 1. That ceiling is asserted in
 * `DispositionOfferFormServiceTest` rather than described, because the failure mode of a fourth
 * query added later is invisible on a single-record screen.
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE DOES NOT APPLY, AND THE REASON IS
 * STRUCTURAL RATHER THAN CONVENIENT. That rule's own exemption is for methods that are
 * "structurally single-record-per-transaction": this one takes a SINGLE `Id`, is invoked exactly
 * once per modal open by a `@wire`, has no trigger, no batch and no collection parameter to bulk.
 * There is no loop that a 251st record would force a second pass through, so a 251-record test would
 * exercise no additional code path while proving nothing — the exact anti-pattern that exemption
 * exists to prevent. 🔴 THIS IS NOT A RELAXATION OF "no SOQL/DML in loops", which is honoured in
 * full: the NDA read is one query for every buyer on the sale, never one per buyer. ⚠ IF A CALLER
 * EVER PASSES A COLLECTION, THIS EXEMPTION LAPSES — re-read the rule, do not extend the argument.
 *
 * ── SHARING ───────────────────────────────────────────────────────────────────────────────
 * `with sharing`, and every selector read is `WITH USER_MODE`. A buyer NDA or BOV submission the
 * running user cannot see is simply absent, which correctly narrows the picker rather than offering
 * an option whose save would then be refused.
 *
 * @see force-app/main/default/classes/DispositionOfferFormController.cls (the only caller)
 * @see force-app/main/default/classes/DispositionOfferBuyerStampService.cls (fills Buyer_Name__c)
 * @see force-app/main/default/classes/DispositionBuyerTimelineService.cls (the consumer whose join
 *      Conflict Flag #1 is about)
 * @see agent-output/offer-form-and-stage-retirement.md (§A.3 broker source, §A.4 the NDA gate)
 */
public with sharing class DispositionOfferFormService {

    /**
     * Shown beside the read-only broker so the analyst can see WHY that name is there. Two record
     * types, two sources, two different remedies when it is blank — a bare empty field would send
     * an on-market user to the wrong screen.
     */
    @TestVisible
    private static final String SOURCE_ON_MARKET = 'From the selected BOV submission';

    /** @see SOURCE_ON_MARKET */
    @TestVisible
    private static final String SOURCE_OFF_MARKET = 'From the broker picked on this disposition';

    /**
     * One selectable buyer — a `lightning-combobox` option, deliberately shaped as `{label, value}`
     * rather than as an `NDA__c`.
     *
     * 🔴 `value` IS THE CONTACT ID, NOT THE NDA ID, and that is the whole contract. It is written
     * straight into `Disposition_Offer__c.Buyer__c`, which is the Contact-Id join
     * `DispositionBuyerTimelineService` matches on. Returning the NDA Id would compile, render
     * identically, save without error, and silently populate the buyer lookup with a row that is not
     * a Contact — caught by nothing until the timeline showed blanks.
     */
    public class BuyerOption {
        /** The buyer Contact Id. Written to `Disposition_Offer__c.Buyer__c`. */
        @AuraEnabled
        public String value;

        /**
         * The buyer's display name. `Contact.Name`, falling back to `NDA__c.Counterparty_Name__c`.
         * Never blank — see `resolveName`.
         */
        @AuraEnabled
        public String label;
    }

    /**
     * The whole dialog context in one round trip. Deliberately ONE `@AuraEnabled` return rather than
     * three cacheable methods: the modal cannot render a half-answer (a broker with no buyers is a
     * different screen from a buyer list with no broker), and three wires would be three cache
     * entries that can disagree.
     */
    public class OfferFormContext {
        /**
         * The resolved broker Contact Id, or NULL when none is appointed yet. Written to
         * `Disposition_Offer__c.Broker__c` by the modal.
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
         * the empty-broker hint ("appoint a broker on the BOV matrix" vs "pick a broker on this
         * disposition") — two different screens, so one generic sentence would misdirect half the
         * users.
         */
        @AuraEnabled
        public Boolean isOnMarket;

        /**
         * The selectable buyers, buyer name first. NEVER null; EMPTY is a first-class answer and the
         * modal renders an explained empty state for it rather than an empty picker.
         */
        @AuraEnabled
        public List<BuyerOption> buyers;
    }

    /**
     * Resolves the broker and the selectable buyers for one Disposition.
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
     *   Broker read THROWS          -> broker fields stay empty, THE BUYER LIST STILL LOADS. An FLS
     *                                  gap on `BOV_Submission__c.Broker__c` (which `DPEG_Admin_Access`
     *                                  genuinely lacks — measured) must not take down a dialog whose
     *                                  central control is the buyer picker.
     *   Zero qualifying NDAs        -> `buyers` is empty. 🔴 NOT AN ERROR AND NOT A THROW. The modal
     *                                  explains it, because `Buyer_Required_On_Offer` would refuse
     *                                  the save anyway and the analyst's remedy is on a different
     *                                  object entirely.
     *   Buyer NDA read THROWS       -> propagates. This one is NOT caught: the buyer picker IS the
     *                                  dialog, and silently showing zero buyers when the real cause
     *                                  is a missing grant would send the analyst to create NDAs that
     *                                  already exist. A loud `AuraHandledException` naming the
     *                                  provisioning gap is the correct failure.
     *
     * @param dispositionId The Disposition__c the Log Offer button was clicked on; null-safe.
     * @return A fully-populated context. NEVER null, and no field on it is ever null except
     *         `brokerId`.
     * @throws System.QueryException when the running user cannot read `NDA__c` or the buyer fields
     *         on it. The controller converts it to an `AuraHandledException`.
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
        context.buyers = new List<BuyerOption>();

        if (dispositionId == null) {
            return context;
        }

        // ── 1. The parent: record type (which decides the broker source) and the off-market broker.
        // ⚠ Wrapped because `Broker__c` and the `Contact` traversal are both USER_MODE gates. A
        // persona missing either loses the BROKER, not the whole dialog.
        Disposition__c parent;
        try {
            parent = DispositionSelector.selectBrokerContextById(dispositionId);
        } catch (System.QueryException e) {
            System.debug(
                LoggingLevel.WARN,
                'DispositionOfferFormService: broker context unreadable for '
                    + dispositionId + ' — ' + e.getMessage()
            );
            parent = null;
        }

        // `recordTypeNameOf` is null-safe and answers On_Market for a null/Master record type, so an
        // unreadable parent lands on the same branch a Master-record-type row does. ONE helper, one
        // answer — see DispositionDomain, which exists because two copies of this test disagreed.
        Boolean isOnMarket =
            !DispositionDomain.RT_OFF_MARKET.equals(DispositionDomain.recordTypeNameOf(parent));
        context.isOnMarket = isOnMarket;
        context.brokerSource = isOnMarket ? SOURCE_ON_MARKET : SOURCE_OFF_MARKET;

        // ── 2. The broker. Two sources, and the ON-MARKET one costs a second query — which is why it
        // is inside the branch rather than read unconditionally.
        if (isOnMarket) {
            try {
                for (BOV_Submission__c submission
                        : BovSubmissionSelector.selectSelectedBrokerByDispositionId(dispositionId)) {
                    // ⚠ A `Selected` row can carry a NULL `Broker__c` — the lookup post-dates the
                    // object and legacy submissions have only `Broker_Firm__c`. Keep looking rather
                    // than accepting the first row, so a legacy row does not mask a real one.
                    if (submission.Broker__c != null) {
                        context.brokerId = submission.Broker__c;
                        context.brokerName = resolveContactName(submission.Broker__r);
                        break;
                    }
                }
            } catch (System.QueryException e) {
                // `DPEG_Admin_Access` does not grant `BOV_Submission__c.Broker__c` (measured
                // 2026-08-21). Degrade to "no broker resolved"; the offer is still creatable.
                System.debug(
                    LoggingLevel.WARN,
                    'DispositionOfferFormService: selected-broker read refused for '
                        + dispositionId + ' — ' + e.getMessage()
                );
            }
        } else if (parent != null && parent.Broker__c != null) {
            context.brokerId = parent.Broker__c;
            context.brokerName = resolveContactName(parent.Broker__r);
        }

        // ── 3. The buyers. Deliberately NOT wrapped — see the ApexDoc outcome table.
        context.buyers = toOptions(NdaSelector.selectSignedBuyerNdasByDispositionId(dispositionId));
        return context;
    }

    /**
     * Turns signed buyer NDAs into picker options, DE-DUPLICATED BY CONTACT ID.
     *
     * 🔴 THE DE-DUPLICATION IS NOT TIDINESS. One buyer Contact can be named on two NDAs on the same
     * sale — an NDA re-issued rather than amended is the ordinary way there — and a
     * `lightning-combobox` with two options sharing a `value` renders both while only ever selecting
     * the first, which reads to the user as a dead menu item. SOQL has no `SELECT DISTINCT`, so the
     * selector cannot do this and its header says so.
     *
     * ⚠ FIRST ROW WINS, and the selector's `ORDER BY Buyer__r.Name ASC, CreatedDate ASC, Id ASC`
     * makes "first" deterministic. Because both rows resolve to the SAME Contact, the two labels can
     * only differ when one falls back to `Counterparty_Name__c` — and the fallback is the worse
     * label, so preferring the earlier row is also preferring the better one.
     *
     * @param ndas Signed buyer-role NDAs from `NdaSelector`; every row has a non-null `Buyer__c`.
     * @return Options in the selector's order, one per distinct buyer Contact. Never null.
     */
    private static List<BuyerOption> toOptions(List<NDA__c> ndas) {
        List<BuyerOption> options = new List<BuyerOption>();
        Set<Id> seen = new Set<Id>();
        for (NDA__c nda : ndas) {
            if (nda.Buyer__c == null || seen.contains(nda.Buyer__c)) {
                continue;
            }
            seen.add(nda.Buyer__c);
            BuyerOption option = new BuyerOption();
            option.value = nda.Buyer__c;
            option.label = resolveBuyerLabel(nda);
            options.add(option);
        }
        return options;
    }

    /**
     * The name to show for a buyer: `Contact.Name`, else the NDA's own `Counterparty_Name__c`, else
     * a stable placeholder.
     *
     * ⚠ IT MIRRORS `DispositionBuyerTimelineService.resolveName`'s PREFERENCE ORDER ON PURPOSE — the
     * picker and the timeline must call the same party the same thing, or an analyst picks "Acme
     * Capital" and the card beside it says "Jane Doe".
     * ⚠ THE `Buyer__r` CAN BE NULL EVEN WHEN `Buyer__c` IS NOT: `USER_MODE` returns the Id but not
     * the related sObject when the running user cannot see that Contact under SHARING (mode lifts
     * FLS, never sharing). That is a REACHABLE state, not a defensive nicety.
     * 🔴 IT NEVER RETURNS BLANK. An empty `label` renders a `lightning-combobox` option as a blank
     * row that is selectable and indistinguishable from the next one.
     *
     * @param nda A signed buyer NDA with `Buyer__c` non-null.
     * @return A non-blank display name.
     */
    private static String resolveBuyerLabel(NDA__c nda) {
        String contactName = resolveContactName(nda.Buyer__r);
        if (String.isNotBlank(contactName)) {
            return contactName;
        }
        if (String.isNotBlank(nda.Counterparty_Name__c)) {
            return nda.Counterparty_Name__c;
        }
        // Reachable: a pre-2026-08-20 NDA later given a Buyer__c the running user cannot see under
        // sharing, with no counterparty text. Naming the state beats rendering an empty row.
        return 'Unnamed buyer';
    }

    /**
     * `contact.Name` when the related sObject came back, '' when it did not.
     *
     * ⚠ ALWAYS A STRING, NEVER NULL — every consumer of this value crosses the `@AuraEnabled`
     * boundary into an LWC, where a null bound to an element attribute renders the literal text
     * "undefined" (measured in this repo, `lwc-attribute-stringification`).
     *
     * @param contact The traversed Contact, or null.
     * @return The name, or ''.
     */
    private static String resolveContactName(Contact contact) {
        return (contact == null || contact.Name == null) ? '' : contact.Name;
    }
}
