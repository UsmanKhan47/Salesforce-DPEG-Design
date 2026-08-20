/**
 * Keeps `BOV_Submission__c.Broker_Firm__c` and `BOV_Submission__c.Contact_Name__c` (both stored
 * Text(255)) in agreement with `BOV_Submission__c.Broker__c` (Lookup to Contact, filtered to the
 * `Contact.Broker` RECORD TYPE — ⚠ CORRECTED same day; this read "filtered `Is_Broker__c = true`",
 * and the broker definition moved. This service reads neither and is unaffected) — added
 * 2026-08-20 with the BOV broker-contact dropdown
 * (`agent-output/bov-broker-contact-lookup-requirements.md` §3, D-1).
 *
 * The analyst now PICKS a broker Contact instead of typing a firm and a person. Both Text fields
 * SURVIVE UNCHANGED IN THE SCHEMA and keep being populated — only the WRITER changes, from a human
 * to this stamp. That is what lets all six existing consumers keep working with zero code change:
 * `BovSubmissionTriggerHandler` (which copies `Broker_Firm__c` onto `Disposition__c
 * .Selected_Broker__c` on approval), `BovSubmissionService.replaceSelectedBroker`, the
 * `Broker_Display__c` formula (`Broker_Firm__c & " — " & Contact_Name__c`), `BovController`'s
 * `BovRow.brokerFirm` / `.contactName`, and the two LWCs that render them.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS IS THE SIBLING OF `DispositionBrokerStampService`, AND IT COPIES ITS SKELETON, NOT
 *    ITS BODY (design C-3). THE DIFFERENCE IS NOT COSMETIC.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * That service composes ONE field (`Selected_Broker__c`) out of TWO parts, so it owns a
 * `SEPARATOR` constant, a `composeLabel()` helper and a 121 + 3 + 120 = 244 ≤ 255 length proof.
 *
 * THIS service copies TWO fields STRAIGHT ACROSS. There is no composition, therefore:
 *   - NO `SEPARATOR` constant. Do not add one. There is nothing to separate.
 *   - NO `composeLabel()`. `Contact_Name__c` IS `Contact.Name`; `Broker_Firm__c` IS
 *     `Contact.Broker_Firm__c`.
 *   - NO combined length arithmetic to make. The two lengths are INDEPENDENT and each is
 *     trivially safe: `Contact.Name` ≤ 121 (FirstName 40 + space + LastName 80) into Text(255),
 *     and `Contact.Broker_Firm__c` is Text(120) into Text(255). **No truncation logic exists and
 *     none should be added** — a `left(255)` here would be dead code that silently starts
 *     mattering if someone widens a source field, which is the wrong place to discover it. If
 *     either source is ever widened, re-do the arithmetic HERE.
 *
 * WHAT IS COPIED VERBATIM IN SUBSTANCE: the change-keyed detection, the two-pass
 * collect-then-assign structure, the one-query-per-chunk budget, the before-context lock
 * argument, the reuse of `ContactSelector.selectBrokerLabelsByIds` (`WITH SYSTEM_MODE`), the
 * null-oldMap-on-insert handling, and the "no Contact resolved ⇒ leave the text unchanged" branch.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY BEFORE-CONTEXT, AND WHY THAT IS A LOCK ARGUMENT RATHER THAN A PREFERENCE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `Broker_Finalize_Approval` declares `recordEditability = AdminOnly` on `BOV_Submission__c`, so a
 * POST-SAVE second DML against a submission whose own approval is pending throws
 * ENTITY_IS_LOCKED — and `AccessLevel.SYSTEM_MODE` does not lift a lock. A Queueable does not fix
 * it either: a pending approval outlives the job. An IN-MEMORY assignment inside the save the user
 * was ALREADY permitted to make costs ZERO extra DML and no lock can refuse it. Identical shape and
 * identical reasoning to `DispositionStageEntryService.stampListingDates` and to
 * `DispositionBrokerStampService`.
 *
 * ⚠ `BovSubmissionTrigger` had NO before context before 2026-08-20 and its header argued that it
 * should not have one. That argument was about the PARENT write and is retracted in place in the
 * trigger file; read it there before concluding the two statements disagree.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY A SERVICE RATHER THAN LOGIC IN THE HANDLER
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The stamp needs a CONTACT SOQL READ, and `.claude/rules/apex-layering-rule.md` prohibits SOQL in
 * a TriggerHandler and prohibits SOQL in a Domain. A Service calling a Selector is the only
 * conforming home. ⚠ `BovSubmissionTriggerHandler`'s own header sets a precedent for keeping
 * trivial logic in the handler, and that precedent explicitly does NOT cover this — it is
 * conditioned on the logic having *"ZERO inline SOQL"*, which this does not satisfy.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THE NEW BEFORE CONTEXTS CANNOT COLLIDE WITH ANY OTHER WRITER (design D-4)
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The guard is STRUCTURAL, not a matter of timing: this stamp fires ONLY when `Broker__c` CHANGES,
 * and every other writer of this object leaves `Broker__c` untouched, so each one re-enters this
 * method and is SKIPPED:
 *
 *   workflows/BOV_Submission__c Set_Broker_Approval_Approved / _Rejected -> Approval_Status__c
 *   BovSubmissionService.replaceSelectedBroker  -> Submission_Status__c, Approval_Status__c
 *   TestDataFactory.createBovSubmissions        -> both Text fields directly, never Broker__c
 *   An analyst editing terms / score / status   -> BOV Terms fields
 *
 * 🔴 THE `TestDataFactory` ROW IS WHY EVERY EXISTING BOV TEST STAYS GREEN BY CONSTRUCTION. The
 * factory sets `Broker_Firm__c` and `Contact_Name__c` and leaves `Broker__c` NULL, so on insert
 * `null == null` reads as "unchanged" and this stamp never overwrites the fixture. **Do not change
 * `TestDataFactory.createBovSubmissions`**; a test that needs a broker sets `Broker__c` itself from
 * `TestDataFactory.createBrokerContact(s)` (the lookup filter is active and non-optional, so a
 * plain `createContacts()` Contact is refused).
 *
 * ⚠ WHERE THEY WOULD COLLIDE, THIS SERVICE WINS, AND THAT IS CORRECT. A single save that both
 * changed `Broker__c` AND hand-typed a firm ends with the stamp, because a before trigger sees the
 * final field values and overwrites. Stated so nobody has to re-derive it.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ THE RENAME BLIND SPOT (identical to the sibling's code-review W5)
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Keyed on `Broker__c` CHANGING, so editing the same broker Contact's own `FirstName`, `LastName`
 * or `Broker_Firm__c` never fires this trigger at all (the submission row was not touched) and
 * leaves BOTH Text fields — and therefore the `Broker_Display__c` formula over them — stale until
 * the next save that actually changes `Broker__c`. No mitigation exists today; it is named here so
 * it is not rediscovered as a bug.
 *
 * ⚠ LEGACY ROWS ARE SKIPPED FOREVER, BY DESIGN (design R-3). Existing submissions carry Text values
 * and a NULL `Broker__c`; `null == null` is "unchanged", so they are never touched and the
 * comparison matrix keeps rendering them. **No backfill is in scope and none is needed.**
 *
 * ── LAYERING / BUDGET / BULK ──────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). ZERO inline SOQL — the Contact read goes to
 * `ContactSelector.selectBrokerLabelsByIds`, `WITH SYSTEM_MODE` for automation-path reasons argued
 * at that method. ZERO DML at any record count: this mutates `Trigger.new` in place, returns void.
 *
 * BUDGET: **AT MOST 1 SOQL AND EXACTLY 0 DML PER CHUNK — CONSTANT IN THE NUMBER OF SUBMISSIONS.**
 * A chunk in which no record changed `Broker__c` — now the overwhelmingly common case, since these
 * before contexts fire on EVERY `BOV_Submission__c` write in the org — costs ZERO queries. That
 * CONSTANCY, not merely "251 rows produced 251 stamps", is what the bulk tests assert.
 *
 * 🔴 `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE **APPLIES IN FULL AND THERE IS NO
 * EXEMPTION TO CLAIM.** This is a trigger path and it loops over a collection. The
 * per-transaction-singleton exemption does not apply, and neither does the
 * `.claude/rules/content-publication-rule.md` carve-out — no content object is involved.
 *
 * ── FLS ───────────────────────────────────────────────────────────────────────────────────
 * A before-trigger field assignment is an in-memory SObject mutation and is NOT FLS-checked, so a
 * persona without EDIT on `Broker_Firm__c` / `Contact_Name__c` still gets the stamp — the same
 * outcome `DispositionStageEntryService.stampListingDates` and `LeadConvertService` record for
 * their own stamps. A missing grant makes the value invisible to that persona; it does not disable
 * the stamp.
 * ⚠ THE FLS THAT DOES BITE THIS FEATURE IS ON THE READ SIDE AND IS NOT HERE. `Broker__c` must be
 * granted in `DPEG_Disposition_Edit` / `DPEG_Disposition_View` before anyone — System Administrator
 * included — can see or set the picker, because a Metadata-API-deployed custom field arrives with
 * NO field permissions for ANY profile. 🔴 IF SOMEONE HITS `QueryException: No such column` AFTER
 * DEPLOY, THE FIX IS A PERMISSION SET, EVERY TIME — not `WITH SYSTEM_MODE` (design R-9). No
 * `BovSubmissionSelector` USER_MODE query is widened by this change; all three read the derived
 * Text, never the lookup (design C-5).
 *
 * ── SHARING ───────────────────────────────────────────────────────────────────────────────
 * `with sharing`. `SYSTEM_MODE` on the selector read lifts CRUD/FLS and NEVER sharing, so a Contact
 * the running user cannot SEE is simply absent from the result and correctly falls into the "leave
 * both texts unchanged" branch. **Do not add a `without sharing` inner class for this.**
 *
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/ContactSelector.cls (the SYSTEM_MODE label read)
 * @see force-app/main/default/classes/DispositionBrokerStampService.cls (the sibling — SKELETON
 *      shared, BODY deliberately not)
 * @see scripts/seed-broker-contacts.apex (the SetNull-cascade guard that must know about
 *      `BOV_Submission__c.Broker__c` and about these two STORED Text fields)
 */
public with sharing class BovSubmissionBrokerStampService {

    /**
     * Stamps `Broker_Firm__c` and `Contact_Name__c` from `Broker__c` for every record whose
     * `Broker__c` CHANGED in this save. Mutates `newSubmissions` in place; performs no DML.
     *
     * ── THE FOUR OUTCOMES, AND WHY EACH IS THE SAFE DIRECTION ─────────────────────────────
     *
     *   `Broker__c` UNCHANGED         -> the record is skipped ENTIRELY. Neither Text field is
     *                                    read, written or considered. 🔴 THIS IS THE BRANCH THAT
     *                                    PROTECTS EVERY OTHER WRITER (class header, design D-4)
     *                                    and the reason every existing fixture stays green.
     *   `Broker__c` CLEARED to null   -> BOTH `Broker_Firm__c` and `Contact_Name__c` are set to
     *                                    null, IN THE SAME SAVE. A submission with no broker
     *                                    lookup must not keep displaying a broker's firm and name
     *                                    in the comparison matrix, and `Broker_Display__c` is a
     *                                    formula over BOTH texts, so leaving either behind would
     *                                    render half a broker beside an empty picker.
     *   `Broker__c` SET, Contact read -> `Contact_Name__c = broker.Name` and
     *                                    `Broker_Firm__c = broker.Broker_Firm__c`. Straight copy,
     *                                    both fields, always together. See the blank-firm note.
     *   `Broker__c` SET, NO Contact   -> BOTH Text fields are left UNCHANGED (design D-1).
     *                                    Blanking is the more destructive direction, and a stale
     *                                    pair beside a lookup the user can see is visible and
     *                                    self-healing — the next successful save re-stamps it.
     *
     * ⚠ "NO Contact" COVERS TWO REACHABLE CASES AND TREATS THEM IDENTICALLY ON PURPOSE: the row is
     * not visible to the running user under sharing, or the row was deleted between the pick and
     * this save. Both mean "I cannot author truthful values", and inventing a different behaviour
     * per case would be two ways to be wrong instead of one way to be inert.
     *
     * ── 🔴 THE BLANK-FIRM DECISION, STATED EXPLICITLY BECAUSE IT IS A CHOICE ──────────────
     * A resolved Contact whose own `Broker_Firm__c` is BLANK yields `Broker_Firm__c = null` on the
     * submission — the blank is COPIED, not skipped, and `Contact_Name__c` is still stamped.
     *
     * The rejected alternative was "leave `Broker_Firm__c` alone when the Contact's firm is blank",
     * which sounds conservative and is actually the dangerous one: on a broker CHANGE from A to B,
     * it would leave A's FIRM sitting next to B's NAME. `Broker_Display__c` renders
     * `Broker_Firm__c & " — " & Contact_Name__c`, so the matrix would show a person who does not
     * work at the firm named beside them — a fabricated broker that no human typed and no field
     * disagrees with. A blank firm is visibly incomplete; a hybrid is invisibly wrong.
     *
     * ⚠ THE TWO FIELDS ARE THEREFORE ALWAYS WRITTEN AS A PAIR. There is no path in this method that
     * writes one and not the other. If a future change adds one, it must argue against the
     * paragraph above.
     *
     * @param newSubmissions Trigger.new. Null/empty-safe.
     * @param oldMap         Trigger.oldMap on update; NULL ON INSERT — on insert every non-null
     *                       `Broker__c` counts as a change, and a null one is skipped, so an
     *                       ordinary insert that names no broker costs nothing.
     * @example
     * BovSubmissionBrokerStampService.stampBrokerFields(newList, oldMap);
     */
    public static void stampBrokerFields(
        List<BOV_Submission__c> newSubmissions,
        Map<Id, BOV_Submission__c> oldMap
    ) {
        if (newSubmissions == null || newSubmissions.isEmpty()) {
            return;
        }

        // PASS 1 — detect. Collects the records to restamp and the Contacts to resolve, so the
        // query below is issued once for the whole chunk rather than once per record.
        List<BOV_Submission__c> changed = new List<BOV_Submission__c>();
        Set<Id> brokerIds = new Set<Id>();

        for (BOV_Submission__c submission : newSubmissions) {
            // On insert oldMap is null and priorBroker is null, so being CREATED with a broker
            // counts as a change. The `Id == null` guard mirrors the sibling service.
            BOV_Submission__c prior = (oldMap == null || submission.Id == null)
                ? null
                : oldMap.get(submission.Id);
            Id priorBroker = (prior == null) ? null : prior.Broker__c;
            if (submission.Broker__c == priorBroker) {
                continue;
            }
            changed.add(submission);
            if (submission.Broker__c != null) {
                brokerIds.add(submission.Broker__c);
            }
        }

        if (changed.isEmpty()) {
            // The common case: zero queries, zero DML, zero writes.
            return;
        }

        // ONE query for the whole chunk — never one per record. `selectBrokerLabelsByIds` returns
        // an empty list WITHOUT querying when the set is empty, so a chunk in which every changed
        // record merely CLEARED its broker also costs zero queries.
        Map<Id, Contact> brokerById = new Map<Id, Contact>(
            ContactSelector.selectBrokerLabelsByIds(brokerIds)
        );

        // PASS 2 — assign. In-memory only.
        for (BOV_Submission__c submission : changed) {
            if (submission.Broker__c == null) {
                submission.Broker_Firm__c = null;
                submission.Contact_Name__c = null;
                continue;
            }
            Contact broker = brokerById.get(submission.Broker__c);
            // ⚠ An absent key means the Contact is unreadable under sharing or was deleted. Both
            // leave BOTH Text fields exactly as they were — see the ApexDoc's fourth outcome.
            if (broker == null) {
                continue;
            }
            submission.Contact_Name__c = broker.Name;
            // The blank is COPIED deliberately — see "THE BLANK-FIRM DECISION" above. Never guard
            // this with String.isBlank(): that produces B's name beside A's firm.
            submission.Broker_Firm__c = broker.Broker_Firm__c;
        }
    }
}
