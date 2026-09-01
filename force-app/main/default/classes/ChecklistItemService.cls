/**
 * Completion service for `Checklist_Item__c` — the write half of the Phase 3 UI. Owns the DML
 * behind `ChecklistController`: complete an item with an optional comment, and close a
 * wire-fraud verification item only once the verbal verification is captured (DPEG brief
 * Section 06).
 *
 * layer=service (`.claude/rules/apex-layering-rule.md`). ZERO inline SOQL — the one read is
 * `ChecklistItemSelector.selectForCompletion`, which existed from Phase 2 with no production
 * caller and whose caller this class now is. Every public method takes a COLLECTION
 * (ARCHITECTURE.md §2 bulkification); the controller passes singletons because the LWC acts on
 * one row at a time, but nothing here is shaped around that.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS CLASS DELIBERATELY DOES **NOT** REPRODUCE `TransactionTaskService`'s CRUD WORKAROUND,
 *    AND THAT IS THE SINGLE BIGGEST SIMPLIFICATION IN THE WHOLE CHECKLIST REWRITE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `TransactionTaskService` exists in the shape it does for exactly one reason: `Task` object
 * EDIT is **un-grantable by permission set on this platform**. `ObjectPermissions.SobjectType`
 * is a restricted picklist that excludes `Task` / `Event` / `Activity`, a permission set XML
 * carrying such a block deploys green and is then silently discarded (measured 2026-08-28 on
 * usman-dpeg), and profile changes are ruled out for this org. So that class had to
 *   (a) authorise in the APPLICATION via the `Transaction_Task_Actions` custom permission, and
 *   (b) write with `AccessLevel.SYSTEM_MODE` to get past the CRUD nobody can hold.
 *
 * ✅ `Checklist_Item__c` IS AN ORDINARY CUSTOM OBJECT. Its CRUD and FLS are grantable by an
 * ordinary permission set, so the platform can do the authorising and this class writes with
 * `AccessLevel.USER_MODE`. There is NO custom permission gate here, NO `FeatureManagement`
 * call, and NO SYSTEM_MODE anywhere in this file. Per ARCHITECTURE.md §2 a `USER_MODE` failure
 * on a path the user ASKED for is the correct outcome: it reports a real provisioning gap and
 * the fix is a permission set, not a mode change.
 *
 * ⚠ DO NOT "HARDEN" ANY WRITE HERE TO `SYSTEM_MODE`. Doing so re-imports the workaround the
 * custom object removed, and it would silently un-enforce FLS on the wire-fraud evidence fields
 * — the one place in this module where the platform checking who may write what is worth
 * having. If a user reports "I cannot complete a checklist item", the questions are, in order:
 *   1. do they hold Edit on `Checklist_Item__c` (permission set), and
 *   2. do they hold EDIT-level record access to the parent `Transaction__c`?
 * Read access is enough to SEE a row in the checklist and is NOT enough to update it.
 *
 * 🔴 THE PERMISSION GRANT IS PART OF THIS FEATURE'S DEPLOY, NOT A FOLLOW-UP. A
 * Metadata-API-deployed custom object arrives with no `objectPermissions` and its fields with ZERO
 * `FieldPermissions` rows for any profile, System Administrator included. Ship this class without
 * Edit on `Checklist_Item__c` and FLS on `Flag__c` / `Comment__c` / the four wire-evidence fields,
 * and EVERY completion fails for EVERYONE. It fails closed and loudly, which is the right
 * direction — but it is still an outage, and it is the same shape as the 2026-08-28 incident where
 * nobody in the org could complete a checklist Task at all.
 *
 * ── SHARING ─────────────────────────────────────────────────────────────────────────────────
 * `with sharing`, and unlike the Task model it costs nothing to reason about.
 * `Checklist_Item__c` is `ControlledByParent` under `Checklist__c`, itself `ControlledByParent`
 * under a Private-OWD `Transaction__c`. A detail record has no `OwnerId`, so an item cannot be
 * individually reassigned away from the deal team: access to one item on a deal is access to
 * every item on that deal. The whole class of "a reassigned checklist row hid from the service"
 * failure that `TaskSelector`'s header documents cannot occur here.
 *
 * ── AUTHORIZE FIRST, THEN WRITE ─────────────────────────────────────────────────────────────
 * `TransactionTaskService`'s ordering is preserved even though the mechanism changed. Every
 * method resolves its ids through the `USER_MODE` selector FIRST and refuses anything it cannot
 * see or that fails a business rule, BEFORE any DML is attempted. Two reasons this matters and
 * is not ceremony:
 *   • An id the running user cannot read comes back as a MISSING MAP KEY, not an exception.
 *     Treating a missing key as "fine, update it anyway" would hand the user an opaque
 *     `INSUFFICIENT_ACCESS_OR_READONLY` from the DML instead of a sentence they can act on.
 *   • The wire-verification rule (name + phone required) must refuse before anything is
 *     written, or a half-recorded verification lands on an anti-fraud control.
 *
 * ── EXCEPTIONS ──────────────────────────────────────────────────────────────────────────────
 * Three typed, user-safe, user-ACTIONABLE exceptions the controller surfaces VERBATIM, and the
 * raw platform exceptions on anything else (which the controller maps to a fixed generic
 * message). The `AuraHandledException` boundary lives in the CONTROLLER, not here, so this
 * service stays UI-agnostic.
 *   • `WireVerificationException`  — raised by this class, before any DML.
 *   • `ItemNotFoundException`      — raised by this class, before any DML.
 *   • `ChecklistItemPrerequisiteService.PrerequisiteNotMetException` — raised by the
 *     BEFORE-UPDATE trigger DURING the DML and re-typed on the way out by `refusalOrOriginal`.
 *     ⚠ Unlike the first two, this one can also be produced by a write that never passes
 *     through this class at all (Data Loader, REST, Flow) — the gate is a trigger plus a
 *     validation rule, not a service check.
 *
 * ── WHY THERE IS NO `reopen()` AND NO `@InvocableMethod` ────────────────────────────────────
 * Both were considered and deliberately left out, for the reason Phase 2 gave for not building
 * this class at all yet: half-building a public surface with no caller strands it. The LWC
 * disables a completed row's checkbox, so nothing reopens an item; and no Flow completes a
 * checklist item today. Add either the day something calls it, with its own tests — not before.
 * (`.claude/rules/invocable-rule.md` governs the SHAPE of an invocable method when one exists;
 * it does not require inventing one.)
 *
 * @see force-app/main/default/classes/ChecklistController.cls (the thin caller)
 * @see force-app/main/default/classes/ChecklistItemSelector.cls (the one read)
 * @see force-app/main/default/classes/ChecklistItemDomain.cls (the single definition of "done")
 * @see force-app/main/default/classes/TransactionTaskService.cls (the legacy Task-model twin)
 * @see agent-output/design-transaction-fsd-gaps.md §5.1, §5.2, §6.1
 */
public with sharing class ChecklistItemService {

    /**
     * Raised when a wire-verification item is asked to close without the confirmer's name and
     * phone, or when a wire-verification item is routed through plain completion instead of
     * `recordWireVerification`. User-actionable and user-safe: the controller surfaces the
     * message verbatim.
     */
    public class WireVerificationException extends Exception {}

    /**
     * Raised when an item id does not resolve — it does not exist, or the running user cannot
     * read it. DELIBERATELY ONE EXCEPTION FOR BOTH CASES: distinguishing them in the message
     * would tell an unauthorised caller that a record exists, which is precisely what the
     * sharing model is refusing to tell them.
     */
    public class ItemNotFoundException extends Exception {}

    /** `Checklist_Item__c.Comment__c` is a LongTextArea(4000). See `appendComment`. */
    @TestVisible
    private static final Integer COMMENT_MAX_LENGTH = 4000;

    /**
     * Prefix stamped on a comment whose oldest content had to be dropped. See `appendComment`.
     * ⚠ ASCII ONLY, deliberately — this string is written to a LongTextArea through the Metadata
     * /SOAP layer, and an ellipsis character here buys nothing while adding an encoding question
     * to a field that already strips trailing whitespace on save.
     */
    @TestVisible
    private static final String COMMENT_TRUNCATION_MARKER = '...[earlier comments truncated]\n';

    private static final String MESSAGE_NOT_FOUND =
        'This checklist item is no longer available to you. Refresh the page and try again.';

    private static final String MESSAGE_WIRE_EVIDENCE_REQUIRED =
        'Confirmed-by name and phone number are required before this wire-verification item can close.';

    private static final String MESSAGE_WIRE_MUST_USE_VERIFICATION =
        'This is an anti-fraud wire-verification step. Use the Verify Wiring Instructions dialog '
        + 'to record who confirmed the instructions and on what number — it cannot be ticked off directly.';

    private static final String MESSAGE_NOT_A_WIRE_ITEM =
        'This checklist item is not a wire-verification step, so wire-verification details cannot be recorded against it.';

    /**
     * One item to complete, plus the optional comment captured in the confirm dialog.
     *
     * A DTO rather than a `Map<Id, String>` because a map cannot express "complete this item and
     * leave its comment alone" distinctly from "complete this item with a blank comment" without
     * a null-value convention nobody remembers.
     */
    public class CompletionRequest {
        /** The `Checklist_Item__c` to complete. Required. */
        public Id itemId;
        /** Optional free text; blank/null leaves any existing `Comment__c` untouched. */
        public String comment;

        /**
         * @param itemId  the item to complete
         * @param comment optional comment; blank/null leaves the existing comment untouched
         */
        public CompletionRequest(Id itemId, String comment) {
            this.itemId = itemId;
            this.comment = comment;
        }
    }

    /**
     * One wire-fraud verbal verification to record, against one wire-verification item.
     */
    public class WireVerificationRequest {
        /** The `Checklist_Item__c` (an `Is_Wire_Verification__c` row) to close. Required. */
        public Id itemId;
        /** Name of the person who verbally confirmed the wiring instructions. Required. */
        public String verifiedByName;
        /** The independently looked-up number the confirmation was made on. Required. */
        public String phone;
        /** Optional verifier comments, logged ABOVE the standard verification note. */
        public String comment;

        /**
         * @param itemId         the wire-verification item to close
         * @param verifiedByName the confirmer's name (required)
         * @param phone          the number called (required)
         * @param comment        optional verifier comments
         */
        public WireVerificationRequest(Id itemId, String verifiedByName, String phone, String comment) {
            this.itemId = itemId;
            this.verifiedByName = verifiedByName;
            this.phone = phone;
            this.comment = comment;
        }
    }

    /**
     * Completes ordinary checklist items, optionally persisting a comment.
     *
     * ⚠ REFUSES A WIRE-VERIFICATION ITEM THAT HAS NO VERBAL VERIFICATION ON FILE, and that
     * refusal is the point of the method's existence rather than a nicety. `Is_Wire_Verification__c`
     * marks the two anti-fraud calls (B2 and I7); ticking one off without recording who was called
     * and on what number destroys the only evidence the control produces. An item that already
     * carries `Verbal_Verification_Completed__c = true` completes normally — it has its evidence.
     *
     * 🔴 THIS IS A SERVICE-LEVEL GUARD, NOT A PLATFORM-WIDE CONTROL. A Data Loader, a Flow or a
     * REST write bypasses it entirely, exactly as it bypassed the legacy twin. The controls that
     * DO survive those paths are the `ChecklistItemPrerequisiteService` before-update trigger and
     * the `Prerequisite_Must_Be_Met_To_Complete` validation rule, which is why both exist. Do not
     * cite this guard as the reason a bulk load is safe.
     *
     * ⚠ `Completed_By__c` / `Completed_DateTime__c` ARE NOT WRITTEN HERE. `ChecklistItemDomain
     * .stampCompletion` stamps them in the before-update trigger for EVERY writer, not just this
     * one. Setting them here would be a second, competing writer of the same history.
     *
     * @param requests one per item; null/empty-safe (a no-op).
     * @throws ItemNotFoundException when any id does not resolve for the running user. Nothing is
     *         written — the whole batch is refused rather than partially applied.
     * @throws WireVerificationException when an unverified wire item is routed through here.
     * @throws ChecklistItemPrerequisiteService.PrerequisiteNotMetException when the wire-fraud
     *         prerequisite gate refuses the save (B3 while B2 is open, I8 while I7 is open).
     * @throws System.DmlException on any other platform save failure, including an FLS/CRUD denial
     *         (which is a real provisioning gap, not an error to swallow).
     * @example
     * ChecklistItemService.complete(new List<ChecklistItemService.CompletionRequest>{
     *     new ChecklistItemService.CompletionRequest(itemId, 'Signed copy filed.')
     * });
     */
    public static void complete(List<CompletionRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        Set<Id> itemIds = new Set<Id>();
        for (CompletionRequest request : requests) {
            if (request != null && request.itemId != null) {
                itemIds.add(request.itemId);
            }
        }
        if (itemIds.isEmpty()) {
            return;
        }

        // AUTHORIZE FIRST — one USER_MODE read for the whole batch, never one per request.
        Map<Id, Checklist_Item__c> existing = ChecklistItemSelector.selectForCompletion(itemIds);

        List<Checklist_Item__c> payload = new List<Checklist_Item__c>();
        Set<Id> seen = new Set<Id>();
        for (CompletionRequest request : requests) {
            if (request == null || request.itemId == null) {
                continue;
            }
            Checklist_Item__c current = existing.get(request.itemId);
            if (current == null) {
                throw new ItemNotFoundException(MESSAGE_NOT_FOUND);
            }
            if (current.Is_Wire_Verification__c == true && current.Verbal_Verification_Completed__c != true) {
                throw new WireVerificationException(MESSAGE_WIRE_MUST_USE_VERIFICATION);
            }
            if (!seen.add(request.itemId)) {
                // A duplicate id in one batch would produce two rows for the same record in a
                // single DML, which the platform rejects with DUPLICATE_VALUE. Last write wins is
                // wrong here (the comments would differ), so the first request is kept.
                continue;
            }
            Checklist_Item__c row = new Checklist_Item__c(Id = request.itemId);
            row.Flag__c = ChecklistItemDomain.FLAG_COMPLETED;
            if (String.isNotBlank(request.comment)) {
                // Set-if-provided, matching the legacy twin. A blank comment leaves whatever is on
                // file alone rather than erasing it.
                row.Comment__c = request.comment.trim();
            }
            payload.add(row);
        }
        save(payload);
    }

    /**
     * Records a wire-fraud verbal verification and closes the item (DPEG brief Section 06).
     *
     * Writes the confirmer's name, the number called, the timestamp, and appends the standard
     * verification note to `Comment__c`. `Flag__c` becomes `Verified`, NOT `Completed` — the two
     * are both "done" (`ChecklistItemDomain.isDone`), and `Verified` is what tells a reader that
     * evidence is on file rather than that someone ticked a box.
     *
     * ⚠ ORDER: the not-found check runs before the name/phone rule, and both run before any DML.
     * A caller who cannot see the row is told that, not coached on a rule they cannot act on.
     *
     * ⚠ REFUSES AN ITEM THAT IS NOT `Is_Wire_Verification__c`. Recording anti-fraud evidence
     * against an ordinary step would put a `Verified` flag and a verification note on a row that
     * never had a control attached to it, which is worse than useless in an audit.
     *
     * @param requests one per item; null/empty-safe (a no-op).
     * @throws ItemNotFoundException when any id does not resolve for the running user.
     * @throws WireVerificationException when name or phone is blank, or the item is not a
     *         wire-verification step.
     * @throws System.DmlException on a platform save failure.
     * @example
     * ChecklistItemService.recordWireVerification(new List<ChecklistItemService.WireVerificationRequest>{
     *     new ChecklistItemService.WireVerificationRequest(itemId, 'Jane Doe', '+1 713 555 0142', null)
     * });
     */
    public static void recordWireVerification(List<WireVerificationRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        Set<Id> itemIds = new Set<Id>();
        for (WireVerificationRequest request : requests) {
            if (request != null && request.itemId != null) {
                itemIds.add(request.itemId);
            }
        }
        if (itemIds.isEmpty()) {
            return;
        }

        Map<Id, Checklist_Item__c> existing = ChecklistItemSelector.selectForCompletion(itemIds);

        // Hoisted so every row verified by one call carries an identical timestamp and the note
        // text agrees with the field. Also keeps a 200-row batch to ONE Datetime.now().
        Datetime now = Datetime.now();
        List<Checklist_Item__c> payload = new List<Checklist_Item__c>();
        Set<Id> seen = new Set<Id>();
        for (WireVerificationRequest request : requests) {
            if (request == null || request.itemId == null) {
                continue;
            }
            Checklist_Item__c current = existing.get(request.itemId);
            if (current == null) {
                throw new ItemNotFoundException(MESSAGE_NOT_FOUND);
            }
            if (current.Is_Wire_Verification__c != true) {
                throw new WireVerificationException(MESSAGE_NOT_A_WIRE_ITEM);
            }
            if (String.isBlank(request.verifiedByName) || String.isBlank(request.phone)) {
                throw new WireVerificationException(MESSAGE_WIRE_EVIDENCE_REQUIRED);
            }
            if (!seen.add(request.itemId)) {
                continue;
            }
            String verifiedByName = request.verifiedByName.trim();
            String phone = request.phone.trim();
            String note = 'Verified by phone with ' + verifiedByName + ' at ' + phone
                + ' on ' + now.format('MMM d, yyyy h:mm a') + '.';
            String addition = String.isNotBlank(request.comment)
                ? (request.comment.trim() + '\n' + note)
                : note;

            Checklist_Item__c row = new Checklist_Item__c(Id = request.itemId);
            row.Verbal_Verification_Completed__c = true;
            row.Verified_By_Name__c = verifiedByName;
            row.Verification_Phone__c = phone;
            row.Verified_DateTime__c = now;
            row.Comment__c = appendComment(current.Comment__c, addition);
            row.Flag__c = ChecklistItemDomain.FLAG_VERIFIED;
            payload.add(row);
        }
        save(payload);
    }

    /**
     * Appends `addition` to `existing`, keeping the result inside `Comment__c`'s 4,000-character
     * LongTextArea limit.
     *
     * 🔴 WHEN IT DOES NOT FIT, THE **OLDEST** CONTENT IS DROPPED, NOT THE NEWEST — deliberately,
     * and this is the only place in the class where data is discarded. The newest content on this
     * path is the wire-verification note: the one line that records who was called and on what
     * number. Truncating from the end (the obvious `substring(0, 4000)`) would silently delete
     * exactly the audit evidence the anti-fraud control exists to produce, and it would do so with
     * a success toast. A `STRING_TOO_LONG` DmlException was the other option and was rejected: it
     * would refuse a completed phone verification because a comment box filled up, and the
     * controller would render it as the generic "could not be updated" message.
     *
     * ⚠ The dropped region is marked, so a reader can see that history was cut rather than
     * wondering why the comment starts mid-sentence.
     *
     * ⚠ LongTextArea fields STRIP TRAILING WHITESPACE ON SAVE in this org. Do not assert that a
     * composed string survives a DML round-trip byte-for-byte.
     *
     * @param existing the current `Comment__c`; null/blank-safe.
     * @param addition the text to append; assumed non-blank and already trimmed.
     * @return the composed value, never longer than 4,000 characters.
     */
    @TestVisible
    private static String appendComment(String existing, String addition) {
        String composed = String.isBlank(existing) ? addition : (existing + '\n' + addition);
        if (composed.length() <= COMMENT_MAX_LENGTH) {
            return composed;
        }
        if (addition.length() >= COMMENT_MAX_LENGTH) {
            // Pathological: the addition ALONE overflows the field. Keep its TAIL, which holds
            // the standard verification note, and drop the caller's free text ahead of it. No
            // marker — there is no room for one, and a marker that displaced part of the note
            // would defeat the purpose of keeping the tail.
            return addition.substring(addition.length() - COMMENT_MAX_LENGTH);
        }
        Integer keep = COMMENT_MAX_LENGTH - COMMENT_TRUNCATION_MARKER.length();
        if (keep <= 0 || addition.length() >= keep) {
            // ⚠ THIS BRANCH IS WHY THE TWO LENGTH CHECKS ARE SEPARATE. The addition fits the
            // field but leaves no room for both a marker and any history, and the obvious single
            // check (`addition.length() >= keep` -> substring from `length - MAX`) computes a
            // NEGATIVE index for any addition between `keep` and `MAX` characters and throws
            // System.StringException. Return the addition whole: it fits, and every character of
            // it is newer than anything it displaces.
            return addition;
        }
        return COMMENT_TRUNCATION_MARKER + composed.substring(composed.length() - keep);
    }

    /**
     * The single DML in this class. `USER_MODE`, `allOrNone = true`, and a prerequisite refusal
     * re-typed on the way out.
     *
     * `allOrNone = true` is not the default choice elsewhere in this repo and is right here: a
     * partial success would tell the user an item completed when it did not, on a screen whose
     * whole job is telling them what is and is not done. There is exactly one DML statement per
     * public method, so no Savepoint is needed — the platform rolls the statement back itself.
     *
     * @param payload rows to update; null/empty-safe.
     */
    private static void save(List<Checklist_Item__c> payload) {
        if (payload == null || payload.isEmpty()) {
            return;
        }
        try {
            Database.update(payload, true, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            throw refusalOrOriginal(e);
        }
    }

    /**
     * Re-types a save that the wire-fraud prerequisite gate refused, so the controller can surface
     * WHY verbatim instead of the generic write-failure message.
     *
     * 🔴 THE DEFECT THIS PREVENTS, WHICH THE TASK MODEL SHIPPED WITH ONCE ALREADY.
     * `ChecklistItemPrerequisiteService` refuses a completion with `addError` in a before-update
     * trigger, which reaches Apex as a plain `DmlException`. A controller's `catch (Exception)`
     * maps that to *"…refresh the page and try again"* — advice that can NEVER work, because
     * refreshing does not complete the anti-fraud verification. The one message that names the
     * blocking step went to the debug log, so on the only path a human uses, an ENFORCED control
     * looked like a BROKEN PAGE.
     *
     * ⚠ RECOGNITION LIVES IN `ChecklistItemPrerequisiteService.asRefusal`, NOT HERE, and
     * deliberately: it matches against the very constants that produced the text, so the matcher
     * cannot drift from the message. This method only decides what to throw.
     *
     * ⚠ ANYTHING ELSE IS RETURNED UNCHANGED so the controller still maps it to the generic
     * message. This must not become a route for raw `DmlException` text to reach the UI.
     *
     * @param e the DmlException from `save`.
     * @return a `PrerequisiteNotMetException` when the gate refused, otherwise `e` itself.
     */
    private static Exception refusalOrOriginal(DmlException e) {
        ChecklistItemPrerequisiteService.PrerequisiteNotMetException refusal =
            ChecklistItemPrerequisiteService.asRefusal(e);
        if (refusal == null) {
            return e;
        }
        // ⚠ LOGGED HERE BECAUSE THE CONTROLLER WILL NOT. Its System.debug sits in the generic
        // catch, which this branch deliberately routes around — so without this line a refusal
        // leaves NO trace anywhere, and a FALSE refusal (a mis-stamped Blocked_By__c, a sharing
        // gap hiding the prerequisite) would be undiagnosable: the user gets an explanation and
        // the org keeps no record that the save was even attempted.
        System.debug(LoggingLevel.WARN, 'ChecklistItemService: wire-fraud prerequisite gate refused '
            + 'a checklist completion. ' + refusal.getMessage());
        return refusal;
    }
}
