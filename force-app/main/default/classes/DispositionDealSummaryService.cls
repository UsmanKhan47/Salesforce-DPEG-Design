/**
 * THE DISPOSITION DEAL SUMMARY — the NDA, LOI and PSA state of one sale, on one card, on every
 * stage. Backs `c/dispositionDealSummary` through `DispositionDealSummaryController`.
 * Tranche 2 Workstream C (design D5), 2026-08-20.
 *
 * Layering: orchestration only (ARCHITECTURE.md §2). **ZERO SOQL and ZERO DML of its own** — every
 * read is a selector call (`DispositionSelector`, `NdaSelector`, `LoiSelector`,
 * `ContractReviewSelector`), and this class does nothing but sequence those four reads and shape
 * the result. `.claude/rules/apex-layering-rule.md`.
 *
 * ═══ 🔴 THE FAIL-SOFT POLICY IS THE DESIGN, NOT AN ERROR-HANDLING DETAIL ═══
 * Each read gets its OWN NARROW try/catch and degrades ONE ROW. There is deliberately no outer
 * catch here that could turn one row's failure into the whole card's. The precedent is
 * `BovController.readNdaStatusFailSoft`, whose reasoning transfers verbatim and is restated
 * because it is load-bearing:
 *
 *   - Every field this class reads is granted to `DPEG_Disposition_View` / `DPEG_Disposition_Edit`
 *     TODAY (all 13 verified in both files on 2026-08-20). But a PermissionSet deploy REPLACES its
 *     entire `<fieldPermissions>` set, so any grant is one unrelated redeploy away from vanishing
 *     — a failure mode this repo has been burned by twice.
 *   - `WITH USER_MODE` **THROWS, it does not degrade**. One missing grant on one field of one
 *     object raises `System.QueryException: No such column` — an FLS denial wearing a schema error.
 *   - Inside a single outer catch that exception becomes one generic message and the ENTIRE card
 *     disappears. `c/dispositionDealSummary` is placed UNGATED on `Disposition_Record_Page`, so it
 *     renders on **all 11 stages**: a card that red-banners is a permanent eyesore on every stage
 *     of every sale, not a transient one on four. Degrading one row is strictly better.
 *   - `catch (Exception)`, not `catch (QueryException)`: the failure being defended against is an
 *     FLS/CRUD denial, which the platform reports as a QueryException today, but nothing in this
 *     contract depends on the type and a narrower catch only re-opens the card-blanking path for a
 *     neighbouring failure.
 *
 * ⚠ THE CATCHES DO NOT SUBSTITUTE FOR THE GRANTS. Both are required (design §0 C-1). Which is
 * exactly why the degraded state is VISIBLE — see the next block.
 *
 * ═══ 🔴 A DEGRADED ROW IS LABELLED, AND THIS IS A DELIBERATE DIVERGENCE FROM THE PRECEDENT ═══
 * `BovController.readNdaStatusFailSoft` returns null for BOTH "no NDA exists" and "the read
 * failed", and `c/bovOutreach` renders both as "No NDA" — the two are documented there as
 * intentionally indistinguishable. **This class does not copy that half of the precedent**, and
 * the reason is measured rather than aesthetic: design §0 C-1 found that the BOV pill has
 * *probably been rendering "No NDA" forever* for every disposition-only persona, because
 * `NDA__c.Disposition__c` was not granted to either disposition permission set and `USER_MODE`
 * enforces FLS on `WHERE` fields too. The fail-soft catch worked exactly as designed and hid a
 * real provisioning gap for months, because a degraded row and an empty row looked identical.
 *
 * So each row carries its own `...Unavailable` flag. An empty row says "no LOI yet"; a degraded
 * row says it could not be read. Same blast radius (one row), but the gap is visible to the
 * person who can fix it. ⚠ Do not "simplify" these three booleans away — they are the difference
 * between a card that reports a permissions bug and a card that impersonates an empty sale.
 *
 * ═══ ⚠ THE THREE ROW IDs COST NOTHING AND CHANGED NO SELECTOR (2026-08-21) ═══
 * The DTO carries `ndaId` / `loiId` / `psaId` so the card's row labels can be click-through links.
 * No selector field list moved, and that is a MEASURED property of SOQL rather than a lucky
 * coincidence: **`Id` is returned by every SOQL query whether or not it appears in the SELECT
 * list**, and all three `selectLatest…ByDispositionId` methods list it explicitly anyway. So there
 * is no new field on any `WITH USER_MODE` read — which matters, because every field added to such
 * a SELECT is an FLS gate that THROWS rather than degrades. `Id` is not FLS-gated at all (it has
 * no `FieldPermissions` row on any permission set, verified against `usman-dpeg` 2026-08-21), so
 * there is nothing to grant and nothing new that can fail.
 * 🔴 The Ids are assigned INSIDE each try, after the selector returns. A degraded row therefore
 * carries a null Id and the client cannot render a link to a record the reader was just refused.
 *
 * ═══ WHY FOUR CATCHES FOR THREE ROWS ═══
 * The NDA row is fed by TWO reads — the parent's maintained counters and the latest child NDA —
 * which live on different objects with independent FLS. One catch across both would let a missing
 * grant on `Disposition__c.NDA_Count__c` also erase a perfectly readable NDA status. They get one
 * catch each, and the row shows whichever half survived.
 *
 * @see DispositionDealSummaryController.cls
 * @see force-app/main/default/lwc/dispositionDealSummary/dispositionDealSummary.js
 * @see BovController.readNdaStatusFailSoft (the fail-soft precedent)
 */
public with sharing class DispositionDealSummaryService {

    /**
     * The whole card's payload. Every member is nullable: the client renders null as an empty
     * state, never as a zero or a placeholder value it invented.
     */
    public class DealSummary {

        // ── NDA row ────────────────────────────────────────────────────────────────────────
        /**
         * `Disposition__c.NDA_Count__c` — RAW, and null on a pre-existing row rather than 0.
         * 🔴 Deliberately NOT coalesced here. The field is maintained by the `NDA_Signed_Rollup`
         * after-save flow and holds null on every Disposition that predates it or has never had an
         * NDA; every reader in this repo wraps it in `BLANKVALUE(...,0)`, and the client does that
         * once (design D5). Coalescing in Apex as well would make a real null indistinguishable
         * from a real zero on the wire.
         */
        @AuraEnabled public Integer ndaCount;
        /** `Disposition__c.Signed_NDA_Count__c` — RAW and nullable, for the reason above. */
        @AuraEnabled public Integer ndaSignedCount;
        /** True when the counter read itself failed. The client shows the row as unreadable. */
        @AuraEnabled public Boolean ndaCountsUnavailable = false;
        /** Latest `NDA__c.Status__c` for this sale; null when the sale has no NDA. */
        @AuraEnabled public String ndaStatus;
        /** Latest `NDA__c.Date_Signed__c`; null until an NDA is signed. */
        @AuraEnabled public Date ndaSignedDate;
        /** True when the Disposition has at least one NDA (distinguishes empty from unreadable). */
        @AuraEnabled public Boolean hasNda = false;
        /** True when the latest-NDA read failed. */
        @AuraEnabled public Boolean ndaUnavailable = false;
        /**
         * The latest `NDA__c`'s Id — the click-through target for the card's NDA row label.
         * 🔴 NULL ON A DEGRADED ROW, AND THAT IS PART OF THE THREE-STATE CONTRACT, NOT AN
         * OVERSIGHT. It is assigned only inside `applyLatestNda`'s try, AFTER the selector has
         * returned, so a read that threw leaves it null and the client renders a muted,
         * unlinked label beside the `Unavailable` pill. A degraded row must never offer a link
         * to a record the reader was just refused.
         */
        @AuraEnabled public String ndaId;

        // ── LOI row ────────────────────────────────────────────────────────────────────────
        /**
         * Latest `LOI__c.Stage__c` — the sale's real LOI vocabulary (Received -> Under Review ->
         * Countered by DPEG -> Counter Received from Buyer -> Executed).
         * 🔴 `LOI_Status__c` is NOT carried here and must not be added: no automation sets it, so
         * on a disposition it reads its `Draft` default beside a Stage of `Executed` (§0 C-10).
         * 🔴 `LOI_Signed_Date__c` is NOT carried either: `LOI_Signed_Status_Sync` keys on the
         * ACQUISITION terminal `Stage__c = 'Signed'`, so on a sale it is structurally always blank
         * (§0 C-11). Both exclusions are stated again on `LoiSelector.selectLatestByDispositionId`
         * and in the LWC header, on purpose — an unexplained omission gets "fixed".
         */
        @AuraEnabled public String loiStage;
        /** Latest `LOI__c.Offer_Price__c`; null when not yet priced. */
        @AuraEnabled public Decimal loiOfferPrice;
        /**
         * Latest `LOI__c.Ball_In_Court__c`. ⚠ The vocabulary INVERTS by side: on a sale 'Seller'
         * means DPEG and 'Buyer' means the counterparty. Correct as rendered on a disposition
         * page; do not reuse this DTO behind an acquisition surface without re-labelling.
         */
        @AuraEnabled public String loiBallInCourt;
        /** True when the Disposition has at least one LOI. */
        @AuraEnabled public Boolean hasLoi = false;
        /** True when the LOI read failed. */
        @AuraEnabled public Boolean loiUnavailable = false;
        /**
         * The latest `LOI__c`'s Id — the click-through target for the card's LOI row label.
         * Null on a degraded row, for the reason spelled out on `ndaId`.
         * ⚠ This is an Id, NOT a re-opening of the C-10 / C-11 exclusions above. It carries no
         * status, no date and no vocabulary; it is the row's address, not its content.
         */
        @AuraEnabled public String loiId;

        // ── PSA row ────────────────────────────────────────────────────────────────────────
        /**
         * Latest `Contract_Review__c.Negotiation_Status__c` — the SOURCE field, not the derived
         * `Stage__c` projection, which collapses four negotiation states into three. See
         * `ContractReviewSelector.selectLatestByDispositionId`.
         */
        @AuraEnabled public String psaStatus;
        /** Latest `Contract_Review__c.Execution_Date__c`; null until the PSA is executed. */
        @AuraEnabled public Date psaExecutionDate;
        /** Latest `Contract_Review__c.Latest_Version__c` — maintained by `PsaVersionService`. */
        @AuraEnabled public Integer psaLatestVersion;
        /** True when the Disposition has at least one Contract Review. */
        @AuraEnabled public Boolean hasPsa = false;
        /** True when the PSA read failed. */
        @AuraEnabled public Boolean psaUnavailable = false;
        /**
         * The latest `Contract_Review__c`'s Id — the click-through target for the PSA row label.
         * Null on a degraded row, for the reason spelled out on `ndaId`.
         */
        @AuraEnabled public String psaId;
    }

    /**
     * Reads the NDA / LOI / PSA state of one Disposition for the Deal Summary card.
     *
     * ⚠ IT DOES NOT THROW ON A BAD OR MISSING ID, AND THAT IS INTENTIONAL. A null Id — which the
     * client sends for one render tick before `recordId` is injected — yields an empty summary, so
     * the card shows its empty state rather than flashing an error. A read failure yields a
     * summary with that row flagged unavailable. The only exceptions that can escape are ones no
     * row-level catch could sensibly own (e.g. a heap or CPU limit), which the controller maps to
     * a user-safe message.
     *
     * ⚠ SINGLE-RECORD BY CONSTRUCTION, and therefore exempt from the 251-record mandate in
     * `.claude/rules/bulk-test-rule.md` under that rule's per-transaction-singleton exemption:
     * this is a record-page read for exactly one Disposition, invoked once per page load. There is
     * no loop to force a second batch and no collection entry point to bulkify — four
     * `LIMIT 1`-shaped selector calls, fixed, regardless of data volume. That is stated here so
     * review does not demand a volume test that could not exercise any additional code path.
     *
     * @param dispositionId The Disposition__c whose deal state to summarise; null-safe.
     * @return A fully-populated summary; never null. Rows the running user cannot read are flagged
     *         unavailable rather than omitted.
     */
    public static DealSummary summarise(Id dispositionId) {
        DealSummary summary = new DealSummary();
        if (dispositionId == null) {
            return summary;
        }

        applyNdaCounts(summary, dispositionId);
        applyLatestNda(summary, dispositionId);
        applyLatestLoi(summary, dispositionId);
        applyLatestPsa(summary, dispositionId);

        return summary;
    }

    /**
     * The parent's maintained NDA counters, failing soft.
     *
     * ⚠ Its own catch, separate from the latest-NDA read that shares the same card row: the two
     * live on different objects with independent FLS, and a missing grant on a counter must not
     * also erase a readable NDA status.
     *
     * @param summary       The summary being built; mutated in place.
     * @param dispositionId The Disposition to read.
     */
    private static void applyNdaCounts(DealSummary summary, Id dispositionId) {
        try {
            Disposition__c disposition = DispositionSelector.selectNdaCountsById(dispositionId);
            if (disposition == null) {
                return;
            }
            // .intValue() on a nullable Decimal, guarded — the NULL IS PRESERVED on purpose so the
            // client can tell "never counted" from "counted zero" (see the DTO member's Javadoc).
            summary.ndaCount = (disposition.NDA_Count__c == null)
                ? null
                : disposition.NDA_Count__c.intValue();
            summary.ndaSignedCount = (disposition.Signed_NDA_Count__c == null)
                ? null
                : disposition.Signed_NDA_Count__c.intValue();
        } catch (Exception e) {
            summary.ndaCountsUnavailable = true;
            System.debug(LoggingLevel.ERROR, 'DispositionDealSummaryService NDA counter read degraded on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
        }
    }

    /**
     * The latest child NDA's status and signed date, failing soft.
     *
     * @param summary       The summary being built; mutated in place.
     * @param dispositionId The Disposition to read.
     */
    private static void applyLatestNda(DealSummary summary, Id dispositionId) {
        try {
            NDA__c nda = NdaSelector.selectLatestSummaryByDispositionId(dispositionId);
            if (nda == null) {
                return;
            }
            summary.hasNda = true;
            summary.ndaId = nda.Id;
            summary.ndaStatus = nda.Status__c;
            summary.ndaSignedDate = nda.Date_Signed__c;
        } catch (Exception e) {
            summary.ndaUnavailable = true;
            System.debug(LoggingLevel.ERROR, 'DispositionDealSummaryService NDA read degraded on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
        }
    }

    /**
     * The latest child LOI's stage, price and ball-in-court, failing soft.
     *
     * @param summary       The summary being built; mutated in place.
     * @param dispositionId The Disposition to read.
     */
    private static void applyLatestLoi(DealSummary summary, Id dispositionId) {
        try {
            LOI__c loi = LoiSelector.selectLatestByDispositionId(dispositionId);
            if (loi == null) {
                return;
            }
            summary.hasLoi = true;
            summary.loiId = loi.Id;
            summary.loiStage = loi.Stage__c;
            summary.loiOfferPrice = loi.Offer_Price__c;
            summary.loiBallInCourt = loi.Ball_In_Court__c;
        } catch (Exception e) {
            summary.loiUnavailable = true;
            System.debug(LoggingLevel.ERROR, 'DispositionDealSummaryService LOI read degraded on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
        }
    }

    /**
     * The latest child Contract Review's negotiation status, execution date and version, failing
     * soft.
     *
     * @param summary       The summary being built; mutated in place.
     * @param dispositionId The Disposition to read.
     */
    private static void applyLatestPsa(DealSummary summary, Id dispositionId) {
        try {
            Contract_Review__c psa = ContractReviewSelector.selectLatestByDispositionId(dispositionId);
            if (psa == null) {
                return;
            }
            summary.hasPsa = true;
            summary.psaId = psa.Id;
            summary.psaStatus = psa.Negotiation_Status__c;
            summary.psaExecutionDate = psa.Execution_Date__c;
            summary.psaLatestVersion = (psa.Latest_Version__c == null)
                ? null
                : psa.Latest_Version__c.intValue();
        } catch (Exception e) {
            summary.psaUnavailable = true;
            System.debug(LoggingLevel.ERROR, 'DispositionDealSummaryService PSA read degraded on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
        }
    }
}
