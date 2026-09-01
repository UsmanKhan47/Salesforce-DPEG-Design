/**
 * Trigger handler for `NDA__c` — the FIRST one this object has ever had (created 2026-08-20,
 * Tranche 2 Workstream D). Extends the project's `TriggerHandler` base per
 * `.claude/rules/apex-layering-rule.md`, so `NdaTrigger` itself is one line and every context this
 * handler does not override inherits a safe no-op.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS HANDLER CURRENTLY ROUTES **NOTHING**. THAT IS THE INTENDED STATE, NOT AN OVERSIGHT.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * It used to route:
 *
 *   before insert -> NdaBuyerStampService.stampBuyerName (in-memory, ZERO DML)
 *   before update -> NdaBuyerStampService.stampBuyerName (in-memory, ZERO DML)
 *
 * Both routes, and `NdaBuyerStampService` itself, were RETIRED 2026-09-01 as the second wave of
 * commit `9af0b9d` ("Broker-only model: drop buyer identity", 2026-08-21). That commit stripped
 * every `FieldPermissions` grant for `NDA__c.Buyer__c` from `DPEG_Disposition_Edit` and
 * `DPEG_Disposition_View` — DPEG communicates only with the appointed broker, so buyer identity is
 * gone from the disposition surface — and marked the field `🔴 SUPERSEDED`, noting that retiring the
 * CODE was "its own sequenced wave". This is that wave. `NdaBuyerStampService`,
 * `NdaBuyerStampServiceTest` and both `override` methods here were deleted; nothing replaced them.
 *
 * ⚠ `NDA__c.Buyer__c` ITSELF STILL EXISTS AS METADATA AND IS DELIBERATELY UNTOUCHED. Field
 * retirement was scoped as a SEPARATE, later step and has not been authorised. Do not read this
 * file as licence to drop the field, and do not "restore" its FLS to make the old stamp work — the
 * grants were removed on purpose. See `objects/NDA__c/fields/Buyer__c.field-meta.xml`.
 *
 * ⚠ THE DENORMALISED TEXT FIELD SURVIVES AND IS AGAIN ANALYST-TYPED. `NDA__c.Counterparty_Name__c`
 * (Text(120)) pre-dates the lookup and is still read by `NdaSelector.ExpiryAlertReads`,
 * `NdaExpiryService`'s reminder body, `DispositionBuyerTimelineService`'s legacy fallback, and the
 * NDA layouts. Retiring the stamp returns its ONLY writer to the human who types it — which is what
 * it was before 2026-08-20. No backfill is needed and none is in scope: every row the stamp ever
 * wrote keeps the value it was given.
 *
 * ⚠ THE TWIN IS STILL LIVE. `DispositionOfferBuyerStampService` (same skeleton, different ceiling
 * and clear-branch) still runs from `DispositionOfferTriggerHandler` against
 * `Disposition_Offer__c.Buyer__c`, which is a DIFFERENT field on a DIFFERENT object with its own
 * grants. It was NOT part of `9af0b9d` and is NOT retired here. `ContactSelector.selectNamesByIds`
 * therefore keeps a live caller and must not be deleted as orphaned.
 *
 * ── 🔴 WHY THE TRIGGER AND THIS HANDLER SURVIVE AN EMPTY ROUTE TABLE ────────────────────────
 * `NdaTrigger` is the one-trigger-per-object slot for `NDA__c` (ARCHITECTURE.md §2 /
 * `.claude/rules/apex-layering-rule.md`), and its own header reserves it: *"Any FUTURE `NDA__c`
 * automation belongs in `NdaTriggerHandler`, never in a second trigger file."* Deleting the pair to
 * save a dispatch would hand the next contributor a blank object and invite exactly the second
 * trigger file that rule forbids. The cost of keeping it is one `switch` that falls through to an
 * inherited no-op: `TriggerHandler.run()` dispatches `BEFORE_INSERT`/`BEFORE_UPDATE` to the base's
 * empty virtual methods. ZERO SOQL, ZERO DML, no behaviour of any kind.
 *
 * ── ⚠ THE ACQUISITION HALF OF A DUAL-MODULE OBJECT PASSES THROUGH HERE TOO ──────────────────
 * This handler is invoked for EVERY `NDA__c` save in the org, acquisition NDAs included, and is not
 * scoped by record type or parent lookup. That was load-bearing while the stamp existed (the
 * blast-radius argument is in `NdaTrigger`'s header); with no routes registered it is now merely
 * true. Any automation added here inherits the same org-wide reach and must re-make that argument
 * for itself rather than assume this file already did.
 *
 * ── BUDGET ──────────────────────────────────────────────────────────────────────────────────
 * EXACTLY 0 SOQL and EXACTLY 0 DML per chunk, in every context, unconditionally. `NDA__c` inserts
 * and updates were MEASURED green through this path on 2026-09-01 (rolled-back probe, both record
 * types plus an update). With nothing routed there is no bulk behaviour to falsify, so
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate has no subject here; `NdaTrigger`'s single
 * executable line is covered incidentally by every NDA-inserting suite in the repo
 * (`NdaSelectorTest`, `NdaExpiryServiceTest`, `NdaApprovalServiceTest`, `NdaSignedStatusSyncTest`,
 * `DispositionBuyerTimelineTest`, and `TestDataFactory.createNdas`'s many callers). 🔴 The mandate
 * returns in full the moment anything is routed here again.
 *
 * ── SHARING ─────────────────────────────────────────────────────────────────────────────────
 * `with sharing`, per the project standard.
 *
 * @see force-app/main/default/triggers/NdaTrigger.trigger (the one-line trigger; its header still
 *      describes the retired stamp's change-key as the blast-radius guard — historical context for
 *      why the trigger was safe to introduce, not a description of live behaviour)
 * @see force-app/main/default/classes/TriggerHandler.cls (the base, and the source of the no-ops)
 * @see force-app/main/default/objects/NDA__c/fields/Buyer__c.field-meta.xml (SUPERSEDED, retained)
 * @see force-app/main/default/classes/DispositionOfferBuyerStampService.cls (the surviving twin)
 */
public with sharing class NdaTriggerHandler extends TriggerHandler {
    // No contexts overridden. See the class header — the two before-context routes were retired
    // 2026-09-01 with NdaBuyerStampService. Every context falls through to TriggerHandler's
    // inherited no-op.
}
