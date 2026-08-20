/**
 * Keeps `Disposition__c.Selected_Broker__c` (Text) in agreement with `Disposition__c.Broker__c`
 * (Lookup to Contact) on the OFF-MARKET path — added 2026-08-20 with the off-market broker lookup
 * (design §1.5 / §1.6).
 *
 * The analyst now PICKS a broker Contact instead of typing a name. `Selected_Broker__c` survives as
 * the DENORMALISED DISPLAY VALUE for the three off-market surfaces that can only render a string —
 * the `Broker Selection` Path step, the `Broker_Selection_Approval` approval page, and the
 * on-market BOV chain that still writes it — and this service is what stamps it, so the lookup and
 * the text a human reads cannot disagree AS A RESULT OF A SAVE THAT CHANGES `Broker__c`.
 *
 * ⚠ THAT QUALIFIER IS LOAD-BEARING (code review W5, 2026-08-20) — "can never disagree" is too
 * strong. This service is keyed on `Broker__c` CHANGING (see below), so it is BLIND to a Contact
 * RENAME: editing the same broker's `FirstName`, `LastName` or `Broker_Firm__c` never fires this
 * trigger at all (the Disposition row was not touched), so `Selected_Broker__c` goes permanently
 * stale on the approval page and the Path step until the next save that actually changes
 * `Broker__c`. No mitigation exists for this today; it is named here so it is not rediscovered as
 * a surprise.
 *
 * ── 🔴 WHY A BEFORE-CONTEXT SERVICE AND NOT A FLOW, AN AFTER-TRIGGER, OR THE LWC ──
 * The pick is a DYNAMIC FORMS INLINE FIELD EDIT. There is no button click to hook, so the LWC layer
 * cannot see it; and inline edit is only one writer among API calls, Flows, data loads and the seed
 * scripts. A trigger is the only place that catches all of them.
 *
 * BEFORE, specifically, and the reason is a lock rather than a preference. `Broker_Selection_Approval`
 * declares `recordEditability = AdminOnly`, so a POST-SAVE update to the same Disposition while its
 * own approval is pending throws ENTITY_IS_LOCKED — the exact class of failure that produced
 * `DispositionNdaStampQueueable`, and one a Queueable does NOT fix (a pending approval outlives the
 * job; see `DispositionStageEntryService.stampListingDates`, which reaches this same conclusion for
 * `Listing_Date__c`). An in-memory assignment inside the save the user was ALREADY permitted to make
 * costs ZERO extra DML and no lock can refuse it.
 *
 * ── 🔴 WHY A SEPARATE SERVICE RATHER THAN LOGIC IN THE HANDLER ──────────────
 * The stamp needs a CONTACT SOQL READ, and `.claude/rules/apex-layering-rule.md` prohibits SOQL in a
 * TriggerHandler and prohibits SOQL in a Domain. A Service calling a Selector is the only conforming
 * home. ⚠ `BovSubmissionTriggerHandler`'s header sets a precedent for keeping trivial logic in the
 * handler, and that precedent explicitly does NOT apply here — it is conditioned on the logic having
 * *"ZERO inline SOQL"*, which this does not.
 *
 * ── 🔴 ONE FIELD, TWO STAMP FORMATS. STATED RATHER THAN HIDDEN (design §1.5, risk R4) ──
 * `Selected_Broker__c` will read differently depending on which path wrote it:
 *
 *   ON-MARKET  (`BovSubmissionTriggerHandler`, `BovSubmissionService`)  ->  `Firm`
 *   OFF-MARKET (this service)                                          ->  `Person - Firm`
 *
 * That divergence is DELIBERATE, not an oversight and not something to harmonise. The two paths
 * approve two different things: on-market approves a FIRM'S BOV RESPONSE (the value copied is
 * `BOV_Submission__c.Broker_Firm__c`), whereas off-market approves a NAMED INDIVIDUAL — the approval
 * file's own comment says *"on this path that field IS the decision"*. Stamping the firm alone
 * off-market would render the approval page and the Path step as `"CBRE"` for a decision that was
 * about a specific person, losing the identity of the very thing being signed off.
 *
 * 🔴 THE CONSEQUENCE IS A STANDING RULE: **NO CONSUMER MAY PARSE `Selected_Broker__c`.** It is a
 * display string only. Nothing parses it today; keep it that way. A parser would work on whichever
 * path its author tested and fail silently on the other.
 *
 * ── 🔴 WHY THIS CANNOT COLLIDE WITH THE ON-MARKET WRITERS ───────────────────
 * The stamp is keyed on `Broker__c` CHANGING, and the on-market chain never touches `Broker__c`. So
 * when `BovSubmissionTriggerHandler` updates a parent Disposition, this service sees
 * `d.Broker__c == prior.Broker__c` and skips the record entirely, leaving the firm string it just
 * wrote alone. That is a structural guarantee, not a timing one, and it is what the "an update that
 * does not touch Broker__c leaves Selected_Broker__c unchanged" test exists to pin.
 *
 * ⚠ WHERE THEY WOULD COLLIDE, THIS SERVICE WINS, AND THAT IS CORRECT. A single save that both
 * changed `Broker__c` and set `Selected_Broker__c` by hand ends with the stamp, because a before
 * trigger sees the final field values and overwrites. It is unreachable today (`Broker__c` is
 * rendered only on off-market rows) but the precedence is stated so nobody has to re-derive it.
 *
 * ⚠ NO RECORD-TYPE GUARD IN THIS SERVICE, DELIBERATELY. The scoping to off-market is STRUCTURAL:
 * `Broker__c` is exposed on off-market rows only (a field-level `visibilityRule` on
 * `Disposition_Record_Page`), so a row whose `Broker__c` changes is an off-market row. An
 * `Is_On_Market__c` test here would be a SECOND, DRIFTING COPY of that same rule — two places to
 * change, one of which nobody would remember.
 *
 * ── LAYERING / BUDGET / BULK ────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). ZERO inline SOQL — the Contact read goes to
 * `ContactSelector.selectBrokerLabelsByIds`, `WITH SYSTEM_MODE` for automation-path reasons argued
 * at that method. ZERO DML at any record count: this mutates `Trigger.new` in place and returns void.
 *
 * BUDGET: **AT MOST 1 SOQL AND EXACTLY 0 DML PER CHUNK — CONSTANT IN THE NUMBER OF DISPOSITIONS.**
 * A chunk in which no record changed `Broker__c` — the overwhelmingly common case, since this fires
 * on EVERY `Disposition__c` write in the org — costs ZERO queries. That constancy, not merely "251
 * rows produced 251 stamps", is the property the bulk test must assert.
 *
 * 🔴 `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE **APPLIES IN FULL** AND THERE IS NO
 * EXEMPTION TO CLAIM. This is a trigger path and it loops over a collection. The
 * per-transaction-singleton exemption (which `DispositionApprovalService` legitimately holds) does
 * NOT apply, and neither does the `.claude/rules/content-publication-rule.md` carve-out — no content
 * object is involved.
 *
 * ── FLS ─────────────────────────────────────────────────────────────────────
 * A before-trigger field assignment is an in-memory SObject mutation and is NOT FLS-checked, so a
 * persona without EDIT on `Selected_Broker__c` still gets the stamp — the same outcome
 * `DispositionStageEntryService.stampListingDates` and `LeadConvertService` record for their own
 * stamps. A missing grant makes the value invisible to that persona; it does not disable the stamp.
 * ⚠ The FLS that DOES bite this feature is on the READ side and is not here — see
 * `DispositionSelector.selectApprovalContextById`, which is `WITH USER_MODE` and needs
 * `Disposition__c.Broker__c` granted in `DPEG_Disposition_Edit` / `DPEG_Disposition_View` before
 * Submit for Approval works for anyone, on any stage, on either record type.
 *
 * @see force-app/main/default/classes/DispositionTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/ContactSelector.cls (the SYSTEM_MODE label read)
 * @see force-app/main/default/classes/DispositionStageEntryService.cls (the sibling before-context
 *      stamp, and the full ENTITY_IS_LOCKED argument this one inherits)
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (the on-market writer this
 *      must never fight)
 */
public with sharing class DispositionBrokerStampService {

    /**
     * The separator between person and firm — ASCII hyphen-minus with single spaces, NOT an em dash
     * and NOT an en dash. It matches the strings the existing off-market fixtures already use
     * (`'CBRE - Direct Pick'`, `'Cushman & Wakefield - Direct Pick'`), so the format this service
     * produces is the format the module already reads.
     */
    @TestVisible
    private static final String SEPARATOR = ' - ';

    /**
     * Stamps `Selected_Broker__c` from `Broker__c` for every record whose `Broker__c` CHANGED in
     * this save. Mutates `newDispositions` in place; performs no DML.
     *
     * ── THE FOUR OUTCOMES, AND WHY EACH IS THE SAFE DIRECTION ───────────────
     *
     *   `Broker__c` UNCHANGED          -> the record is skipped ENTIRELY and `Selected_Broker__c` is
     *                                     not read, not written and not considered. This is the
     *                                     branch that protects the on-market chain (class header).
     *   `Broker__c` CLEARED to null    -> `Selected_Broker__c = null`, IN THE SAME SAVE. Leaving the
     *                                     old name behind would put a broker's name on the approval
     *                                     page and the Path step of a disposition that HAS no
     *                                     broker, and the approval gate would then refuse a record
     *                                     that looks complete — corruption that reads as health.
     *   `Broker__c` SET, Contact read  -> `Name` when `Broker_Firm__c` is blank, otherwise
     *                                     `Name + ' - ' + Broker_Firm__c`.
     *   `Broker__c` SET, NO Contact    -> `Selected_Broker__c` is left UNCHANGED (design §1.5).
     *                                     Blanking is the more destructive direction, and a stale
     *                                     string next to a lookup the user can see is visible and
     *                                     self-healing — the next successful save re-stamps it.
     *
     * ⚠ "NO Contact" COVERS TWO REACHABLE CASES AND TREATS THEM IDENTICALLY ON PURPOSE: the row is
     * not visible to the running user under sharing, or the row was deleted between the pick and
     * this save. Both mean "I cannot author a truthful string", and inventing a different behaviour
     * per case would be two ways to be wrong instead of one way to be inert.
     *
     * RE-AUTHORED 2026-08-20 (code review Suggestion 5) — this used to list a third case, "the row
     * has no `Name`", which is UNREACHABLE: `Contact.LastName` is required, so a persisted, queried
     * Contact always has a `Name`. `composeLabel`'s own `String.isBlank(broker.Name)` guard (below,
     * in this same class) is kept anyway — it is cheap, and it is what makes the caller's
     * `if (label == null) continue` guard in this method cover the absent-key path too — but nothing
     * observable exercises it, and this ApexDoc must not promise a behaviour that cannot occur.
     *
     * ── LENGTH IS PROVEN, NOT TRUNCATED (design §1.5) ───────────────────────
     * `Contact.Name` ≤ 121 (FirstName 40 + space + LastName 80); `Contact.Broker_Firm__c` is
     * Text(120); the separator is 3. Worst case 121 + 3 + 120 = **244 ≤ 255**, the width of
     * `Selected_Broker__c`. **No truncation logic is needed and none should be added** — a
     * `left(255)` here would be dead code that silently starts mattering if someone widens
     * `Broker_Firm__c` without re-checking this arithmetic, which is exactly the wrong place to
     * discover it. If either source field is ever widened, re-do the arithmetic HERE.
     *
     * ── ORDERING AGAINST THE SIBLING BEFORE-CONTEXT STAMP ───────────────────
     * `DispositionTriggerHandler` calls `DispositionStageEntryService.stampListingDates` first and
     * this second. The order is IRRELEVANT — the two write disjoint fields (`Listing_Date__c` vs
     * `Selected_Broker__c`) and neither reads the other's output. It is stated so a future reader
     * does not have to re-derive it, and so nobody "fixes" an ordering that carries no meaning.
     *
     * @param newDispositions Trigger.new. Null/empty-safe.
     * @param oldMap          Trigger.oldMap on update; NULL ON INSERT — on insert every non-null
     *                        `Broker__c` counts as a change, and a null one is skipped, so an
     *                        ordinary insert that names no broker costs nothing.
     * @example
     * DispositionBrokerStampService.stampSelectedBrokerLabel(newList, oldMap);
     */
    public static void stampSelectedBrokerLabel(
        List<Disposition__c> newDispositions,
        Map<Id, Disposition__c> oldMap
    ) {
        if (newDispositions == null || newDispositions.isEmpty()) {
            return;
        }

        // PASS 1 — detect. Collects the records to restamp and the Contacts to resolve, so the
        // query below is issued once for the whole chunk rather than once per record.
        List<Disposition__c> changed = new List<Disposition__c>();
        Set<Id> brokerIds = new Set<Id>();

        for (Disposition__c d : newDispositions) {
            // On insert oldMap is null and priorBroker is null, so being CREATED with a broker
            // counts as a change. The `d.Id == null` guard mirrors `stampListingDates`.
            Disposition__c prior = (oldMap == null || d.Id == null) ? null : oldMap.get(d.Id);
            Id priorBroker = (prior == null) ? null : prior.Broker__c;
            if (d.Broker__c == priorBroker) {
                continue;
            }
            changed.add(d);
            if (d.Broker__c != null) {
                brokerIds.add(d.Broker__c);
            }
        }

        if (changed.isEmpty()) {
            // The common case: zero queries, zero DML, zero writes.
            return;
        }

        // ONE query for the whole chunk — never one per record. Skipped entirely when every changed
        // record merely CLEARED its broker, so a bulk clear costs no query either.
        Map<Id, String> labelByContactId = new Map<Id, String>();
        for (Contact broker : ContactSelector.selectBrokerLabelsByIds(brokerIds)) {
            labelByContactId.put(broker.Id, composeLabel(broker));
        }

        // PASS 2 — assign. In-memory only.
        for (Disposition__c d : changed) {
            if (d.Broker__c == null) {
                d.Selected_Broker__c = null;
                continue;
            }
            String label = labelByContactId.get(d.Broker__c);
            // ⚠ A null here means EITHER the key is absent (unreadable / deleted Contact) OR the
            // key is present with a null label (a Contact with no Name). Both mean the same thing —
            // "no truthful string is available" — so they are deliberately NOT distinguished, and
            // both leave `Selected_Broker__c` exactly as it was.
            if (label == null) {
                continue;
            }
            d.Selected_Broker__c = label;
        }
    }

    /**
     * The display string for one broker Contact, per design §1.5.
     *
     * A BLANK FIRM YIELDS THE BARE NAME, NOT A TRAILING SEPARATOR. `'Mark Chen - '` would read as
     * truncation on the approval page and would be indistinguishable from a bug, so the separator is
     * only emitted when there is something on the other side of it.
     *
     * @param broker A Contact carrying Name and Broker_Firm__c.
     * @return `Name` when the firm is blank, `Name + ' - ' + Broker_Firm__c` otherwise, or null when
     *         no truthful string can be composed (the caller then leaves the text unchanged).
     */
    private static String composeLabel(Contact broker) {
        if (broker == null || String.isBlank(broker.Name)) {
            return null;
        }
        return String.isBlank(broker.Broker_Firm__c)
            ? broker.Name
            : broker.Name + SEPARATOR + broker.Broker_Firm__c;
    }
}
