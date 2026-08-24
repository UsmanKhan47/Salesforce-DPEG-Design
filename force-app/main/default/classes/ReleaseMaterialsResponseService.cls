/**
 * The Release Materials response logger: reads the responses already logged on one Disposition and
 * appends a new one. Backs `ReleaseMaterialsResponseController` -> `c/releaseMaterialsResponseLog`,
 * which `c/dispositionMain` renders at the `Release Materials` stage. Added 2026-08-24.
 *
 * A "response" is what comes back after the offering materials go out: the broker asks MORE
 * QUESTIONS, gives a DECISION, or signals an OFFER. One row per response.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE BROKER IS **RESOLVED**, NEVER PICKED, AND NEVER ACCEPTED FROM THE CLIENT.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * User decision, 2026-08-24: *"lookup to the appointed broker only"*. There is exactly ONE
 * appointed listing broker per sale, so a picker would be a control with one correct answer and
 * several wrong ones. `logResponse` therefore takes NO broker parameter at all — the resolution
 * happens server-side at save time, which is what makes a forged or stale broker Id unexpressible
 * rather than merely discouraged.
 *
 * 🔴 THE RESOLUTION IS **REUSED**, NOT REIMPLEMENTED — AND FROM THE READ-PATH SIBLING, NOT THE
 *    TRIGGER-PATH ONE. READ THIS BEFORE "CORRECTING" THE DEPENDENCY.
 * The rule ("on-market -> the `Selected` `BOV_Submission__c`'s `Broker__c`; off-market ->
 * `Disposition__c.Broker__c`") already exists TWICE in this codebase, at two different layers:
 *
 *   `DispositionStageEntryService.resolveBrokers`   TRIGGER path. Bulk (`Map<Id, Disposition__c>`
 *                                                   straight off `Trigger.new`), `WITH SYSTEM_MODE`
 *                                                   on the BOV read, returns Ids only.
 *   `DispositionOfferFormService.getFormContext`    READ path. Single Id, `WITH USER_MODE`, and it
 *                                                   already returns the broker's NAME and the
 *                                                   record-type SOURCE line a dialog must display.
 *
 * This class calls the SECOND. That is a deliberate departure from the brief, which pointed at the
 * first, and the reason is that this is a read a human asked for on a screen — the same shape the
 * Log Offer dialog has, not the shape a before-insert trigger has. Reusing the trigger-path method
 * would have meant promoting a `private` bulk method, building a fake `Map<Id, Disposition__c>` from
 * a second Disposition read this class does not otherwise need, taking a `SYSTEM_MODE` BOV read on a
 * user-initiated screen, and then STILL resolving the Contact's name with a third query. Every one
 * of those is a step away from the layering rules, and the answer would have been identical.
 * ⚠ A THIRD COPY WAS NEVER AN OPTION. Two copies of this rule already disagree about mode and
 * cardinality; a third would be the one that drifts unnoticed.
 *
 * ⚠ THE COUPLING THIS CREATES, STATED SO IT IS NOT DISCOVERED THE HARD WAY: a change to
 * `getFormContext`'s NULL CONTRACT (today: never null, `brokerId` null when none is appointed) or to
 * its record-type source rule changes THIS card too. That is the price of one definition and it is
 * the right trade — but this class's own tests pin the resolution independently (both record types,
 * plus the no-broker case), so the two cannot start disagreeing silently. If the offer dialog ever
 * needs a resolution rule this card must NOT follow, extract the shared part into its own service at
 * that point; do not fork it here.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ A NULL BROKER IS AN ACCEPTED OUTCOME AND DOES **NOT** BLOCK THE LOG. THIS IS THE OPPOSITE
 *    OF WHAT THE LOG OFFER DIALOG DOES, AND THE DIFFERENCE IS DELIBERATE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `DispositionOfferFormService`'s header explains why an offer naming nobody is refused: with the
 * buyer concept gone, `Broker__c` is the ONLY party on a `Disposition_Offer__c`, so an unattributed
 * offer cannot be told apart from another offer on the same sale and is what an approval would be
 * choosing between. **None of that transfers to a response log.** A response row's value is the
 * METHOD, the NOTES and the TIME — "a decision came back on the 3rd" is a useful, complete entry
 * even before anyone has been appointed, and refusing it would lose the record of a real event to
 * protect a field nothing downstream reads. User instruction, 2026-08-24: *"still allow the entry
 * with a blank broker rather than blocking the log"*.
 * 🔴 SO THE CARD MUST SAY SO, NOT JUST SILENTLY SAVE A NULL. `LogContext.brokerName` is '' and the
 * component renders an explicit "no broker appointed yet" line above the form. A blank read-only
 * field with no explanation is indistinguishable from a broken one.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 "UNREADABLE" IS NOT "UNAPPOINTED". A `QueryException` FROM THE BROKER READ PROPAGATES.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The paragraph above is about a broker that does not EXIST yet. A broker the running user cannot
 * READ is a different thing and is NOT degraded to a blank: `getFormContext` lets its
 * `QueryException` propagate (its own header records that reversal and why), this class does not
 * catch it, and `ReleaseMaterialsResponseController` turns it into a visible ACCESS message. Telling
 * a user "no broker is appointed on this sale" about a sale that has one is the wrong-answer-not-an-
 * error shape this repo has paid for repeatedly.
 * ⚠ AND IT IS NOT REACHABLE FOR THE INTENDED PERSONAS TODAY. `BOV_Submission__c.Broker__c` and
 * `Disposition__c.Broker__c` are both granted read on `DPEG_Disposition_View`,
 * `DPEG_Disposition_Edit` and both PSGs (measured live 2026-08-24 via `FieldPermissions`). ⚠ That
 * contradicts a sentence in `DispositionOfferFormService`'s header which reads as though the grant
 * were generally absent — it names `DPEG_Admin_Access` specifically, which is a DIFFERENT persona
 * and still has no row. The disposition personas are fine.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 SHARING AND MODE — DECIDED AT EACH DECLARATION, NOT INHERITED
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `with sharing`, and EVERY database operation this class reaches runs in `USER_MODE`. There is no
 * `SYSTEM_MODE` anywhere in this feature and no `without sharing` inner class. The full argument:
 *
 *   READ (`ReleaseMaterialsResponseSelector.selectByDispositionId`) — `WITH USER_MODE`. A human
 *   opened the page. All five fields are granted read on both disposition sets (measured), and the
 *   object carries `viewAllRecords = true` on both, so nothing is under-counted.
 *
 *   WRITE (`Database.insert(..., AccessLevel.USER_MODE)`) — 🔴 AND THIS IS THE DECISION THE REPO'S
 *   TWO UAT CYCLES ON 2026-08-21 WERE SPENT ON, SO IT IS ARGUED RATHER THAN ASSERTED. The failure
 *   those cycles found was a NON-OWNER writing to an EXISTING record: every DPEG permission set
 *   grants `viewAllRecords` and NONE grants `modifyAllRecords`, so sharing refused the update, and
 *   `allOrNone = false` swallowed it. **Neither half of that shape exists here.**
 *     · This is an INSERT of a BRAND-NEW row. Record-level sharing has no existing row to consult;
 *       the running user becomes the owner. There is no cross-record write anywhere in this class —
 *       nothing is stamped onto `Disposition__c`, `NDA__c` or `BOV_Submission__c`.
 *     · `allOrNone` is `TRUE`, so a refusal THROWS a `DmlException` instead of being swallowed into
 *       a `SaveResult` nobody reads. That is the specific mechanism that made the earlier defect
 *       invisible, and it is switched off here.
 *     · `DPEG_Disposition_Edit` grants `allowCreate = true` plus `editable = true` on all five
 *       fields (measured), so `USER_MODE` costs the intended persona nothing — and it correctly
 *       REFUSES a `DPEG_Disposition_View` persona, which is the behaviour a read-only role must
 *       have. `SYSTEM_MODE` here would silently let a read-only user write, which is why the
 *       denial case is a test rather than a comment.
 *   ⚠ THE ONE CROSS-RECORD ACCESS THAT DOES APPLY IS **READ** ON THE PARENT: a Lookup insert
 *   requires read access to the referenced `Disposition__c`, or the platform raises
 *   `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY`. `viewAllRecords` on `Disposition__c` satisfies
 *   it for every disposition persona.
 *
 * ── LAYERING / BUDGET / BULK ────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). **ZERO inline SOQL** — the response read goes to
 * `ReleaseMaterialsResponseSelector` and the broker reads go through `DispositionOfferFormService`
 * to `DispositionSelector` / `BovSubmissionSelector`. The only DML is the one insert below.
 *
 * BUDGET: `getLogContext` costs AT MOST 3 SOQL / 0 DML (1 response read + up to 2 broker reads;
 * off-market costs 2, a null Id costs 0). `logResponse` costs AT MOST 2 SOQL / 1 DML. Both ceilings
 * are ASSERTED in `ReleaseMaterialsResponseServiceTest`, not merely described — a fourth query
 * added later is invisible on a single-record screen.
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE DOES NOT ATTACH TO THE WRITE, AND THE
 * REASON IS STRUCTURAL RATHER THAN CONVENIENT — the same argument that rule's own exemption makes
 * and that `DispositionOfferFormService` records: `logResponse` takes SCALARS, is invoked exactly
 * once per Save click, has no trigger, no batch and no collection parameter, and contains no loop a
 * 251st record would force a second pass through. A 251-record test would exercise no additional
 * code path. ⚠ IF A CALLER EVER PASSES A COLLECTION, THIS EXEMPTION LAPSES — re-read the rule, do
 * not extend the argument. 🔴 THE READ IS A DIFFERENT MATTER AND **IS** VOLUME-TESTED: the falsifier
 * that matters there is that the query count stays CONSTANT as rows are added, and it is asserted.
 *
 * ── ⚠ THERE IS NO STAGE GUARD, DELIBERATELY ─────────────────────────────────────────────────
 * This class does not check that the parent is at `Release Materials`. The gate is a RENDER gate in
 * `c/dispositionMain`, and making it a save-time rule would break the legitimate case of recording a
 * response that arrived before the sale moved on — which `Entry_DateTime__c`'s own help text
 * explicitly supports ("backdate it if recording an earlier response"). Adding one would be
 * inventing a rule nobody asked for and losing real events to it.
 *
 * @see force-app/main/default/classes/ReleaseMaterialsResponseController.cls (the thin boundary)
 * @see force-app/main/default/classes/ReleaseMaterialsResponseSelector.cls (the only SOQL)
 * @see force-app/main/default/classes/DispositionOfferFormService.cls (the reused broker resolution)
 * @see force-app/main/default/lwc/releaseMaterialsResponseLog/releaseMaterialsResponseLog.js
 */
public with sharing class ReleaseMaterialsResponseService {

    /**
     * Raised for a user-actionable input violation whose message is user-safe and surfaced VERBATIM
     * to the LWC. Distinct from a platform `DmlException`, which the controller maps to a fixed
     * generic message instead — the same two-clause split `CounterOfferController` makes.
     */
    public class ReleaseMaterialsResponseException extends Exception {}

    /**
     * The three `Method__c` values, as an allow-list checked BEFORE the DML.
     *
     * 🔴 IT IS NOT REDUNDANT WITH THE RESTRICTED PICKLIST, AND THE REASON IS THE MESSAGE, NOT THE
     * ENFORCEMENT. `Method__c` IS a `restricted` value set and Apex DML DOES enforce it (measured
     * repeatedly in this repo — the "restricted picklists are UI-only" claim is false), so the
     * platform is a real backstop. But it refuses with
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST: bad value for restricted picklist field`, which the
     * controller is obliged to replace with a generic message because raw DML text leaks field API
     * names. The user would then see "could not be saved" for a mistake they could have fixed. This
     * list turns that into an authored sentence naming the three choices.
     * ⚠ IT MUST MATCH `objects/Release_Materials_Response__c/fields/Method__c.field-meta.xml`
     * EXACTLY, including case and the space in `More questions`. A drift here does not fail the
     * deploy — it fails the save, at runtime, with this class's own message.
     */
    @TestVisible
    private static final Set<String> ALLOWED_METHODS = new Set<String>{
        'More questions', 'Decision', 'Offer'
    };

    /** Surfaced verbatim when `method` is blank or off the allow-list. Names the three choices. */
    @TestVisible
    private static final String BAD_METHOD_MESSAGE =
        'Pick how this response arrived: More questions, Decision, or Offer.';

    /** Surfaced verbatim when there is no parent to log against. */
    @TestVisible
    private static final String NO_DISPOSITION_MESSAGE =
        'This response could not be logged because no disposition was identified. Refresh the page '
        + 'and try again.';

    /**
     * Rendered wherever a response carries no broker. Byte-identical to
     * `DispositionBuyerTimelineService.NO_BROKER` by intention — the two appear as tiles in ONE
     * merged list on the Buyer Activity timeline, and two different placeholders for the same
     * absence would read as two different states.
     * ⚠ DELIBERATELY NOT SHARED AS ONE CONSTANT. Coupling them would let a change to either card's
     * wording move the other silently; the merged card's Jest suite asserts both tiles render the
     * same string, which is the falsifier that keeps them honest without the coupling.
     */
    @TestVisible
    private static final String NO_BROKER = 'No broker recorded';

    /**
     * One logged response, as the logger card renders it. A DTO across the `@AuraEnabled` boundary
     * (ARCHITECTURE.md §2) — every field is a value the component displays directly.
     */
    public class ResponseRow {

        /** The row's Id — the component's `for:each` key and its record-link target. */
        @AuraEnabled
        public Id responseId;

        /** `Name` — the `RMR-{0000}` AutoNumber. The row's identity, always present. */
        @AuraEnabled
        public String responseName;

        /** Raw `Method__c`. Rendered as the visible badge TEXT, never as a colour alone. */
        @AuraEnabled
        public String method;

        /**
         * `Broker__r.Name`, falling back to `NO_BROKER`. Never null and never blank — a blank cell
         * reads as a rendering failure rather than as missing data.
         */
        @AuraEnabled
        public String brokerName;

        /** `Notes__c`, or null when none was entered. Notes are optional — see `logResponse`. */
        @AuraEnabled
        public String notes;

        /** `Entry_DateTime__c` — when the response HAPPENED, which may be backdated. */
        @AuraEnabled
        public Datetime entryDateTime;
    }

    /**
     * Everything the logger card needs in ONE round trip: the resolved broker, whether this user may
     * log at all, and the rows already logged.
     *
     * ⚠ ONE `@AuraEnabled` RETURN RATHER THAN THREE CACHEABLE METHODS. The card cannot render a
     * half-answer (the record type decides the wording of the "no broker" line as well as the source
     * text), three wires would be three cache entries that can disagree, and one `refreshApex` after
     * a save re-provisions the whole card instead of some of it.
     */
    public class LogContext {

        /**
         * The resolved broker Contact Id, or NULL when none is appointed yet.
         * 🔴 NULL DOES NOT REFUSE THE FORM here — see the class header. It is explained, and the
         * response is logged with a blank broker.
         */
        @AuraEnabled
        public String brokerId;

        /** The broker's display name, or '' when unresolved. NEVER null — see `getLogContext`. */
        @AuraEnabled
        public String brokerName;

        /** Why that broker: the record-type-specific source line. NEVER null. */
        @AuraEnabled
        public String brokerSource;

        /** TRUE when the parent is on the `On_Market` record type. Words the no-broker line. */
        @AuraEnabled
        public Boolean isOnMarket;

        /**
         * TRUE when the running user may create a `Release_Materials_Response__c`.
         *
         * 🔴 AN AFFORDANCE, NEVER THE GUARD. The real enforcement is `AccessLevel.USER_MODE` on the
         * insert, which refuses the write whatever this flag says — and there is a test that runs a
         * read-only persona through `logResponse` to prove it. This exists only so a
         * `DPEG_Disposition_View` user is shown the log without a Save button they would be refused
         * on, rather than a form that fails on click.
         * ⚠ IT IS OBJECT-LEVEL ONLY (`isCreateable()`), which is a DESCRIBE call, not SOQL, and not
         * a sharing check. It cannot see record-level access and does not need to: an insert creates
         * the record it owns.
         */
        @AuraEnabled
        public Boolean canLog;

        /** The rows already logged, NEWEST FIRST. Never null; empty is the normal early state. */
        @AuraEnabled
        public List<ResponseRow> responses;
    }

    /**
     * The logger card's whole context for one Disposition.
     *
     * ── THE OUTCOMES, AND WHY EACH IS THE SAFE DIRECTION ──────────────────────────────────
     *   dispositionId NULL      -> a fully-populated, EMPTY context. Never null and never a throw:
     *                              the card's `@wire` fires before `recordId` is set on a slow first
     *                              render, and a throw there would flash an error on a card that is
     *                              about to work.
     *   No visible Disposition  -> same empty context with `isOnMarket = true`, inherited from
     *                              `DispositionDomain.recordTypeNameOf`'s own Master/unset fallback
     *                              via `getFormContext`. Not re-derived here.
     *   No broker appointed     -> `brokerId` null, `brokerName` ''. NOT an error and NOT a throw;
     *                              the card explains it and still allows the log.
     *   Either read THROWS      -> propagates. See the class header: unreadable is not unappointed.
     *
     * @param dispositionId The Disposition the card is mounted on; null-safe.
     * @return A fully-populated context. NEVER null; no field on it is ever null except `brokerId`.
     * @throws System.QueryException when the running user cannot read
     *         `Release_Materials_Response__c` and its fields, `Disposition__c.Broker__c`,
     *         `BOV_Submission__c.Broker__c` / `Submission_Status__c`, or `Contact`. The controller
     *         converts it to an authored access message.
     * @example
     * ReleaseMaterialsResponseService.LogContext ctx =
     *     ReleaseMaterialsResponseService.getLogContext(dispositionId);
     */
    public static LogContext getLogContext(Id dispositionId) {
        LogContext context = new LogContext();
        context.brokerId = null;
        context.brokerName = '';
        context.brokerSource = '';
        context.isOnMarket = true;
        // The describe is free of SOQL and is evaluated even for a null Id, so a card mounted before
        // its record-id arrives still knows whether to render a form once the Id lands.
        context.canLog = Schema.SObjectType.Release_Materials_Response__c.isCreateable();
        context.responses = new List<ResponseRow>();

        if (dispositionId == null) {
            return context;
        }

        // ── The broker. ONE call, and it is the ONLY definition of this rule this class knows.
        DispositionOfferFormService.OfferFormContext broker =
            DispositionOfferFormService.getFormContext(dispositionId);
        context.brokerId = broker.brokerId;
        context.brokerName = broker.brokerName;
        context.brokerSource = broker.brokerSource;
        context.isOnMarket = broker.isOnMarket;

        // ── The rows. Selector-ordered newest-first; nothing here re-sorts.
        context.responses = getResponses(dispositionId);
        return context;
    }

    /**
     * The logged responses for one Disposition, NEWEST FIRST — the shared read behind BOTH cards.
     *
     * 🔴 IT EXISTS SO THERE IS EXACTLY ONE OWNER OF THIS OBJECT'S QUERY **AND** ITS MAPPING.
     * `DispositionBuyerTimelineService` merges these rows into the Buyer Activity timeline and calls
     * THIS method rather than the selector: routing it through here is what keeps the `NO_BROKER`
     * placeholder, the null-notes contract and the field set in one place. A second consumer calling
     * the selector directly would re-implement `resolveBrokerName` and the two cards would drift
     * apart on the one value most likely to be null.
     *
     * ⚠ THE ORDER IS THE SELECTOR'S AND THIS METHOD DOES NOT RE-SORT. The logger card renders it
     * as-is. The merged timeline RE-SORTS the combined list — that is a property of the merge, not a
     * disagreement with this ordering; see `DispositionBuyerTimelineService.getTimeline`.
     *
     * @param dispositionId The parent sale; null-safe.
     * @return Rows newest first; an EMPTY LIST — never null — when there are none.
     * @throws System.QueryException — see the selector's header for the enumerated gates.
     * @example
     * List&lt;ReleaseMaterialsResponseService.ResponseRow&gt; rows =
     *     ReleaseMaterialsResponseService.getResponses(dispositionId);
     */
    public static List<ResponseRow> getResponses(Id dispositionId) {
        List<ResponseRow> rows = new List<ResponseRow>();
        if (dispositionId == null) {
            return rows;
        }
        for (Release_Materials_Response__c row
                : ReleaseMaterialsResponseSelector.selectByDispositionId(dispositionId)) {
            rows.add(buildRow(row));
        }
        return rows;
    }

    /**
     * Appends one response to a Disposition's log.
     *
     * 🔴 THERE IS NO `brokerId` PARAMETER AND THERE MUST NEVER BE ONE. The appointed broker is
     * RESOLVED here, at save time, from the parent — see the class header. A client-supplied Contact
     * Id would be a forgeable attribution on a record whose whole purpose is attribution, and it
     * would also go stale the moment a broker is replaced while the form sits open.
     *
     * ── ORDER OF OPERATIONS, AND IT MATTERS ─────────────────────────────────────────────────
     * The input is validated BEFORE anything is read. A bad `method` is a mistake the user can fix
     * and must not cost two queries, and — more importantly — the authored message must not be
     * pre-empted by a `QueryException` from an unrelated provisioning gap. (`CounterOfferService`
     * documents the reverse ordering choice for the opposite reason: there, the set of valid tokens
     * is a property of the parent row, so the row has to be read first. Here it is a constant.)
     *
     * ── ⚠ NOTES ARE OPTIONAL, AND THAT IS A DECISION WORTH DISAGREEING WITH ─────────────────
     * A response with a `Method__c` and a time is already a complete, useful entry ("a decision came
     * back on the 3rd"), and the alternative — refusing the save — loses the record of a real event
     * to enforce a rule nobody asked for. Blank/whitespace notes are stored as NULL rather than as
     * '' so the card's em-dash branch has exactly one condition to test.
     *
     * ── ⚠ `allOrNone = TRUE`, AND `SaveResult` IS DELIBERATELY NOT INSPECTED ────────────────
     * With all-or-none on, a refused insert THROWS; `sr.isSuccess()` can never be false, so an
     * `if (!sr.isSuccess())` branch below would be UNREACHABLE — dead code that drags this class
     * under the 75% per-class coverage threshold and rolls a deploy back with every error counter
     * reading zero (this repo has a measured incident of exactly that). The partial-success pattern
     * is the WRONG shape here anyway: there is one record, and a silently-dropped log entry is the
     * failure mode the whole `allOrNone = false` warning in the class header is about.
     *
     * @param dispositionId The parent sale; required.
     * @param method        One of `ALLOWED_METHODS`; required.
     * @param notes         Free-text detail; optional, trimmed, blank stored as null.
     * @throws ReleaseMaterialsResponseException when `dispositionId` is null or `method` is blank or
     *         off the allow-list. The controller surfaces the message VERBATIM.
     * @throws System.DmlException when the running user may not create the record (a
     *         `DPEG_Disposition_View` persona), cannot read the parent
     *         (`INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY`), or the row fails a platform rule.
     *         The controller replaces it with a fixed generic message.
     * @throws System.QueryException from the broker resolution — see the class header.
     * @example
     * ReleaseMaterialsResponseService.logResponse(dispId, 'Offer', 'Verbal at 4.2m, 6.1 cap.');
     */
    public static void logResponse(Id dispositionId, String method, String notes) {
        // 🔴 VALIDATE FIRST — return early, before any read. See the ApexDoc above.
        if (dispositionId == null) {
            throw new ReleaseMaterialsResponseException(NO_DISPOSITION_MESSAGE);
        }
        if (String.isBlank(method) || !ALLOWED_METHODS.contains(method)) {
            throw new ReleaseMaterialsResponseException(BAD_METHOD_MESSAGE);
        }

        // The appointed broker, resolved — never supplied. A null is an accepted outcome.
        DispositionOfferFormService.OfferFormContext broker =
            DispositionOfferFormService.getFormContext(dispositionId);

        Release_Materials_Response__c row = new Release_Materials_Response__c(
            Disposition__c = dispositionId,
            Method__c = method,
            Broker__c = String.isBlank(broker.brokerId) ? null : (Id) broker.brokerId,
            Notes__c = String.isBlank(notes) ? null : notes.trim(),
            // ⚠ SET EXPLICITLY RATHER THAN LEFT TO THE FIELD'S `NOW()` DEFAULT. The default is for
            // the hand-entry path (New button / data loader); relying on it here would make this
            // method's most important value depend on default-value application semantics that
            // differ between construction shapes, and would make a test asserting the stamp
            // vacuous. This card offers no date input, so the entry time is always now.
            Entry_DateTime__c = System.now()
        );

        // 🔴 USER_MODE + allOrNone TRUE. Both halves argued in the class header; neither is
        // inherited from a sibling and neither may be relaxed without re-reading it.
        Database.insert(row, true, AccessLevel.USER_MODE);
    }

    /**
     * One queried row -> one DTO row. Pure: no SOQL, no DML, no state.
     *
     * @param row A response with the selector's field set populated.
     * @return The DTO row. Never null.
     */
    private static ResponseRow buildRow(Release_Materials_Response__c row) {
        ResponseRow dto = new ResponseRow();
        dto.responseId = row.Id;
        dto.responseName = row.Name;
        dto.method = row.Method__c;
        dto.brokerName = resolveBrokerName(row);
        dto.notes = row.Notes__c;
        dto.entryDateTime = row.Entry_DateTime__c;
        return dto;
    }

    /**
     * The broker's display name: the linked Contact, else the fixed placeholder.
     *
     * ⚠ `String.isNotBlank` RATHER THAN A NULL CHECK, AND BOTH HALVES ARE REACHABLE. `Broker__r`
     * can come back null even when `Broker__c` is set — `USER_MODE` lifts FLS, never sharing, so a
     * Contact the running user cannot see under sharing yields the Id without the related sObject.
     * 🔴 IT NEVER RETURNS BLANK. A blank cell reads as a rendering failure rather than as missing
     * data; the placeholder is what tells the analyst no broker was on the sale at the time.
     *
     * @param row The response, with `Broker__r` resolved when `Broker__c` is set and visible.
     * @return A non-blank display name. Never null.
     */
    private static String resolveBrokerName(Release_Materials_Response__c row) {
        if (row.Broker__c != null && row.Broker__r != null && String.isNotBlank(row.Broker__r.Name)) {
            return row.Broker__r.Name;
        }
        return NO_BROKER;
    }
}
