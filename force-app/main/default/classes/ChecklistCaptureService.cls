/**
 * The Phase 5 capture layer: resolves what a checklist item has to record, provisions the record
 * it records into, refuses a completion whose output is missing, and files an uploaded document
 * against both the deal and the item.
 *
 * layer=service. ZERO inline SOQL - every read goes through `LoanSelector` (via `LoanService`),
 * `InsuranceBinderSelector` (via `InsuranceBinderService`) or `ContentDocumentLinkSelector`. Every
 * public method takes a COLLECTION.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE PROBLEM THIS FIXES: 18 OF THE 82 ITEMS HAD NOWHERE TO PUT THEIR ANSWER.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Before Phase 5, completing F9 ("Select bank account type") set `Flag__c = 'Completed'` and
 * recorded WHICH TYPE WAS SELECTED nowhere at all. `Loan__c` and `Insurance_Binder__c` shipped in
 * Phase 1 as empty shells with no writer. A checklist that records that a decision was made but not
 * what the decision WAS is a compliance artefact, not a system of record - and the specific items
 * affected are the financing terms and the insurance binding, i.e. the two places where "we did
 * that" without "here is the number" is least acceptable.
 *
 * ── THE THREE MODES, AND WHY THE APEX IN EACH IS AS SMALL AS IT IS ─────────────────────────
 *   TARGET_FIELDS (F5, F6, F9, F11, F12, G2, G5, J4)
 *     Apex provisions the `Loan__c` / `Insurance_Binder__c` and returns its Id. THE VALUES ARE
 *     WRITTEN BY LIGHTNING DATA SERVICE, not by this class - see `LoanService`'s header for the
 *     full argument. There is no field-name-to-value Apex writer anywhere in Phase 5.
 *   DOCUMENT (C7, G6)
 *     The FILE is uploaded by `lightning-file-upload` straight onto the `Transaction__c`, so the
 *     platform creates the `ContentVersion`. Apex then adds ONE `ContentDocumentLink` from the
 *     same document to the ITEM, for per-item provenance.
 *   DERIVED (A5, B5)
 *     No user input at all. `ChecklistOutcomeService` runs after the completion saves.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 CONTENT QUOTA: THIS CLASS NEVER INSERTS A `ContentVersion` OR A `ContentNote`. NOT ONCE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `.claude/rules/content-publication-rule.md` governs this and it is not an ordinary governor
 * limit: every `ContentVersion` / `ContentNote` insert consumes one of the org's 2,500-per-rolling-
 * 24-hours `ContentPublication` allowance, test rollback does NOT refund it, `Limits` cannot see it,
 * and exceeding it throws a `System.UnexpectedException` that has been MEASURED here to escape
 * `catch (Exception)` AND to be ignored by `Database.insert(records, false)`, aborting the whole
 * transaction including unrelated DML that had already succeeded. It caused a production outage on
 * 2026-08-06.
 *
 * The structural answer is to have no Apex publish path at all:
 *   • The upload is `lightning-file-upload`. The platform creates the `ContentVersion` in ITS OWN
 *     transaction, before any Apex here runs. Nothing this class does can be inside a transaction
 *     that a quota failure would abort.
 *   • `linkDocumentsToItems` inserts only `ContentDocumentLink` rows. A LINK IS A SHARE, NOT A
 *     PUBLICATION - it costs zero quota.
 *   • The completion guard is a `ContentDocumentLink` READ. Reads cost zero quota.
 * ⇒ Phase 5 adds EXACTLY ZERO to the org's production ContentPublication consumption.
 * ⚠ DO NOT "SIMPLIFY" THIS BY TAKING THE FILE AS A BASE64 STRING AND INSERTING THE
 * `ContentVersion` IN APEX. That is the shape the 2026-08-06 incident had. If a future requirement
 * genuinely needs an Apex publish, it must go through the isolation pattern
 * `AttachmentPersistQueueable` establishes and consult `ContentPublicationBudget` first.
 *
 * ── THE GUARD IS SERVICE-LEVEL, NOT A TRIGGER, AND THAT IS A DELIBERATE CEILING ────────────
 * `assertCaptureSatisfied` runs inside `ChecklistItemService.complete`, which means a Data Loader
 * write, a Flow or a REST call completes a capture item without recording its output. That is
 * EXACTLY the same scope the wire-evidence guard in `ChecklistItemService.complete` already has,
 * and it is chosen for a reason that is specific rather than lazy: a before-update trigger gate
 * would refuse `ChecklistMigrationService` (Phase 4 M1, chunked by `ChecklistMigrationQueueable`)
 * wholesale. That migration carries historical
 * completions across from the Task model onto deals that have no `Loan__c` and no uploaded PCR,
 * because the legacy model never had anywhere to put them. A trigger-level requirement would make
 * every one of those rows unmigratable, and `allOrNone = false` would drop precisely them.
 * 🔴 DO NOT CITE THIS GUARD AS A REASON A BULK LOAD IS SAFE. The controls that survive every path
 * are `ChecklistItemPrerequisiteService` and the `Prerequisite_Must_Be_Met_To_Complete` validation
 * rule, and they cover the wire-fraud prerequisite only.
 *
 * ── THIS CLASS NEVER WRITES `Checklist_Item__c` ────────────────────────────────────────────
 * ⚠ The wire-fraud gate refuses ANY coordinate change on an open item, for every principal and
 * every path including `SYSTEM_MODE` - `Blocked_By__c` blanked or repointed while the gate is
 * armed is refused outright. Nothing here updates a `Checklist_Item__c` at all: the capture path
 * writes `Loan__c` / `Insurance_Binder__c` / `ContentDocumentLink`, and the completion itself stays
 * where it already was, in `ChecklistItemService.save`. So no Phase 5 write can trip that gate, and
 * none should be added that does.
 *
 * @see force-app/main/default/classes/ChecklistCaptureDefProvider.cls (the coordinate map)
 * @see force-app/main/default/classes/ChecklistOutcomeService.cls (the DERIVED half)
 * @see force-app/main/default/classes/ChecklistItemService.cls (calls the guard)
 * @see agent-output/design-transaction-fsd-gaps.md §5.9
 */
public with sharing class ChecklistCaptureService {

    /**
     * Raised when an item that must record an output is asked to close without it. User-safe and
     * user-ACTIONABLE - the message names the missing thing, and the controller surfaces it
     * verbatim rather than mapping it to the generic write-failure text.
     */
    public class CaptureRequiredException extends Exception {}

    /**
     * Raised when a capture context cannot be built because the item does not resolve, or its
     * parent deal does not. Deliberately does not distinguish "does not exist" from "you cannot see
     * it", for the same reason `ChecklistItemService.ItemNotFoundException` does not.
     */
    public class CaptureUnavailableException extends Exception {}

    private static final String MESSAGE_UNAVAILABLE =
        'This checklist item is no longer available to you. Refresh the page and try again.';

    /** `ShareType` on a link created by this service. `V` = viewer; the deal remains the owner. */
    private static final String SHARE_TYPE_VIEWER = 'V';

    /**
     * `Visibility` on a link created by this service. `AllUsers` means "everyone who can see the
     * linked record", which for a `ControlledByParent` checklist item is the deal team and nobody
     * else. It does NOT mean org-wide.
     */
    private static final String VISIBILITY_ALL_USERS = 'AllUsers';

    /**
     * Everything the capture dialog needs for one item. UI-AGNOSTIC ON PURPOSE - no `@AuraEnabled`
     * anywhere in this class, so the service can be called from a Flow, a script or a batch without
     * dragging a UI contract along. `ChecklistController` marshals this into its own annotated DTO,
     * exactly as it already does for `ChecklistRow` / `ItemRow`.
     */
    public class CaptureContext {
        /** The `Checklist_Item__c` this context belongs to. */
        public Id itemId;
        /** The parent deal. */
        public Id transactionId;
        /** `TARGET_FIELDS`, `DOCUMENT` or `DERIVED`. */
        public ChecklistCaptureDefProvider.CaptureMode captureMode;
        /** `Loan__c` / `Insurance_Binder__c` for `TARGET_FIELDS`; null otherwise. */
        public String targetObject;
        /**
         * The record the capture form binds to. Populated for `TARGET_FIELDS` (the provisioned
         * `Loan__c` / `Insurance_Binder__c`) and for `DOCUMENT` (the deal, which is where the file
         * is filed). Null for `DERIVED`.
         */
        public Id targetRecordId;
        /** Field API names to render, in order. Empty for `DOCUMENT` and `DERIVED`. */
        public List<String> captureFields;
        /** The field whose absence refuses the completion, or null when nothing is required. */
        public String requiredField;
        /** The refusal text, shown pre-emptively in the dialog so the user is not surprised. */
        public String requirementMessage;
        /** Whether the requirement is ALREADY satisfied, so the dialog can enable Confirm. */
        public Boolean satisfied;
    }

    /**
     * Builds a capture context per item, PROVISIONING the target record where one is needed.
     *
     * 🔴 THIS METHOD PERFORMS DML. It is deliberately not `cacheable` and must never be called from
     * a `@AuraEnabled(cacheable=true)` read - DML in a cacheable method throws at runtime, and the
     * whole checklist screen would go dark on page load rather than when a dialog opens.
     *
     * ⚠ IT IS CALLED WHEN THE DIALOG OPENS, NOT WHEN THE PAGE LOADS, AND THAT IS THE WHOLE REASON
     * A DEAL DOES NOT ACCUMULATE EMPTY `Loan__c` ROWS. `ChecklistController.getChecklist` returns
     * only a boolean per row saying that a capture exists; the record is created the first time a
     * human actually opens one.
     *
     * COST: at most 3 SOQL and 2 DML for a batch of ANY size - one loan read + insert, one binder
     * read + insert, one link read. Zero of each when no item in the batch has a capture def.
     *
     * @param items resolved `Checklist_Item__c` rows carrying `Sequence__c`,
     *              `Checklist__r.Group_Letter__c` and `Checklist__r.Transaction__c` - i.e. exactly
     *              what `ChecklistItemSelector.selectForCompletion` returns. Null/empty-safe.
     * @return Map of item Id -> context, containing ONLY the items that actually record something.
     *         An item with no capture def is ABSENT, which the caller reads as "complete normally".
     * @throws CaptureUnavailableException when an item has no resolvable parent deal.
     * @throws System.DmlException when the target record cannot be created (a CRUD/FLS denial is a
     *         real provisioning gap and must not be swallowed).
     * @example
     * Map&lt;Id, CaptureContext&gt; contexts = ChecklistCaptureService.contextFor(itemsById.values());
     */
    public static Map<Id, CaptureContext> contextFor(List<Checklist_Item__c> items) {
        Map<Id, ChecklistCaptureDefProvider.CaptureDef> defsByItem = defsFor(items);
        Map<Id, CaptureContext> contexts = new Map<Id, CaptureContext>();
        if (defsByItem.isEmpty()) {
            return contexts;
        }

        Map<Id, Id> dealByItem = new Map<Id, Id>();
        Set<Id> loanDeals = new Set<Id>();
        Set<Id> binderDeals = new Set<Id>();
        Set<Id> documentItems = new Set<Id>();
        for (Checklist_Item__c item : items) {
            ChecklistCaptureDefProvider.CaptureDef def = defsByItem.get(item.Id);
            if (def == null) {
                continue;
            }
            Id dealId = item.Checklist__r == null ? null : item.Checklist__r.Transaction__c;
            if (dealId == null) {
                // Fail closed. A capture item whose deal cannot be resolved cannot be provisioned,
                // and quietly returning "no capture needed" would let it complete with no output.
                throw new CaptureUnavailableException(MESSAGE_UNAVAILABLE);
            }
            dealByItem.put(item.Id, dealId);
            if (def.captureMode == ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS) {
                if (ChecklistCaptureDefProvider.TARGET_LOAN.equals(def.targetObject)) {
                    loanDeals.add(dealId);
                } else {
                    binderDeals.add(dealId);
                }
            } else if (def.captureMode == ChecklistCaptureDefProvider.CaptureMode.DOCUMENT) {
                documentItems.add(item.Id);
            }
        }

        Map<Id, Loan__c> loans = LoanService.ensureFor(loanDeals);
        Map<Id, Insurance_Binder__c> binders = InsuranceBinderService.ensureFor(binderDeals);
        Map<Id, Integer> documentCounts = documentCountsByItem(documentItems);

        for (Checklist_Item__c item : items) {
            ChecklistCaptureDefProvider.CaptureDef def = defsByItem.get(item.Id);
            if (def == null) {
                continue;
            }
            Id dealId = dealByItem.get(item.Id);
            CaptureContext context = new CaptureContext();
            context.itemId = item.Id;
            context.transactionId = dealId;
            context.captureMode = def.captureMode;
            context.targetObject = def.targetObject;
            context.captureFields = def.captureFields;
            context.requiredField = def.requiredField;
            context.requirementMessage = def.requirementMessage;

            if (def.captureMode == ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS) {
                SObject target = ChecklistCaptureDefProvider.TARGET_LOAN.equals(def.targetObject)
                    ? (SObject) loans.get(dealId)
                    : (SObject) binders.get(dealId);
                if (target == null) {
                    // ensureFor could neither read nor create it. Fail closed rather than hand the
                    // dialog a null record id it would silently render as a blank create form.
                    throw new CaptureUnavailableException(MESSAGE_UNAVAILABLE);
                }
                context.targetRecordId = target.Id;
                context.satisfied = isRecorded(target, def);
            } else if (def.captureMode == ChecklistCaptureDefProvider.CaptureMode.DOCUMENT) {
                // The FILE is filed against the DEAL - that is what "deal document folder" means in
                // C7 and G6 - and the per-item link is added afterwards by `linkDocumentsToItems`.
                context.targetRecordId = dealId;
                Integer linked = documentCounts.get(item.Id);
                context.satisfied = linked != null && linked > 0;
            } else {
                // DERIVED: nothing to show, nothing to require. The dialog is the ordinary confirm
                // dialog and the outcome runs server-side once the completion saves.
                context.satisfied = true;
            }
            contexts.put(item.Id, context);
        }
        return contexts;
    }

    /**
     * Refuses any item in the batch that must record an output and has not.
     *
     * 🔴 CALLED BEFORE THE COMPLETION DML, NEVER AFTER. `ChecklistItemService` authorises first and
     * writes second, and this guard has to sit on the authorising side: a refusal raised after the
     * update would leave the item ticked and the user reading an error about a step that already
     * looks done.
     *
     * ⚠ THE WHOLE BATCH IS REFUSED, NOT THE OFFENDING ROW. `ChecklistItemService.save` runs
     * `allOrNone = true` for exactly this reason - a partial success on a completion screen tells
     * the user an item completed when it did not.
     *
     * ⚠ AN UNRESOLVABLE TARGET COUNTS AS NOT SATISFIED. `Loan__c` is Private OWD with an ordinary
     * lookup, so it does NOT inherit the deal's sharing the way a checklist item does; a user who
     * cannot read the loan is told the value is missing rather than being waved through on the
     * strength of a query that returned nothing.
     *
     * COST: 0 SOQL when no item in the batch has a capture def, which is 64 of the 82 items.
     *
     * @param items resolved `Checklist_Item__c` rows from
     *              `ChecklistItemSelector.selectForCompletion`; null/empty-safe.
     * @throws CaptureRequiredException naming the missing output, for the FIRST unsatisfied item
     *         encountered in the supplied order.
     * @throws CaptureUnavailableException when an item has no resolvable parent deal.
     * @example
     * ChecklistCaptureService.assertCaptureSatisfied(existing.values());
     */
    public static void assertCaptureSatisfied(List<Checklist_Item__c> items) {
        Map<Id, ChecklistCaptureDefProvider.CaptureDef> defsByItem = defsFor(items);
        if (defsByItem.isEmpty()) {
            return;
        }

        Set<Id> loanDeals = new Set<Id>();
        Set<Id> binderDeals = new Set<Id>();
        Set<Id> documentItems = new Set<Id>();
        for (Checklist_Item__c item : items) {
            ChecklistCaptureDefProvider.CaptureDef def = defsByItem.get(item.Id);
            if (def == null || def.captureMode == ChecklistCaptureDefProvider.CaptureMode.DERIVED) {
                continue;
            }
            if (def.captureMode == ChecklistCaptureDefProvider.CaptureMode.DOCUMENT) {
                documentItems.add(item.Id);
                continue;
            }
            if (def.requiredField == null) {
                // Optional capture (F11). Nothing to prove, so nothing to read.
                continue;
            }
            Id dealId = item.Checklist__r == null ? null : item.Checklist__r.Transaction__c;
            if (dealId == null) {
                throw new CaptureUnavailableException(MESSAGE_UNAVAILABLE);
            }
            if (ChecklistCaptureDefProvider.TARGET_LOAN.equals(def.targetObject)) {
                loanDeals.add(dealId);
            } else {
                binderDeals.add(dealId);
            }
        }

        // ⚠ `existingByDeal`, NOT `ensureFor`. Asking whether an output is on file must never
        // create the record it is asking about - a guard with a side effect would leave an empty
        // Loan__c behind on every refused completion.
        Map<Id, Loan__c> loans = LoanService.existingByDeal(loanDeals);
        Map<Id, Insurance_Binder__c> binders = InsuranceBinderService.existingByDeal(binderDeals);
        Map<Id, Integer> documentCounts = documentCountsByItem(documentItems);

        for (Checklist_Item__c item : items) {
            ChecklistCaptureDefProvider.CaptureDef def = defsByItem.get(item.Id);
            if (def == null || def.captureMode == ChecklistCaptureDefProvider.CaptureMode.DERIVED) {
                continue;
            }
            if (def.captureMode == ChecklistCaptureDefProvider.CaptureMode.DOCUMENT) {
                Integer linked = documentCounts.get(item.Id);
                if (linked == null || linked == 0) {
                    throw new CaptureRequiredException(def.requirementMessage);
                }
                continue;
            }
            if (def.requiredField == null) {
                continue;
            }
            Id dealId = item.Checklist__r.Transaction__c;
            SObject target = ChecklistCaptureDefProvider.TARGET_LOAN.equals(def.targetObject)
                ? (SObject) loans.get(dealId)
                : (SObject) binders.get(dealId);
            if (!isRecorded(target, def)) {
                throw new CaptureRequiredException(def.requirementMessage);
            }
        }
    }

    /**
     * Links already-uploaded documents to the checklist items that produced them.
     *
     * 🔴 INSERTS `ContentDocumentLink` ROWS ONLY - NEVER A `ContentVersion`. The file itself was
     * created by `lightning-file-upload` against the `Transaction__c`, in the platform's own
     * transaction, before this runs. A link is a share, not a publication, so this consumes ZERO
     * `ContentPublication` quota. Read the class header before changing that.
     *
     * ⚠ WHY LINK TO THE ITEM AT ALL, WHEN THE FILE IS ALREADY ON THE DEAL. Without it, "the PCR was
     * uploaded" and "C7 was completed" are two unrelated facts on the same deal, and the completion
     * guard could only ask "does this deal have ANY file?" - which every deal does, so the guard
     * would pass vacuously forever. The per-item link is what makes the guard mean something.
     *
     * ⚠ EXISTING LINKS ARE READ FIRST AND SKIPPED. Re-linking the same document to the same item
     * raises `DUPLICATE_VALUE`, and the LWC can easily fire `uploadfinished` twice for one file on
     * a slow connection.
     *
     * ⚠ `AccessLevel.USER_MODE`. Sharing a document is a write the user asked for; a principal who
     * cannot share it should be refused rather than quietly escalated.
     *
     * @param itemId             the `Checklist_Item__c` the upload belongs to; required.
     * @param contentDocumentIds `ContentDocument` ids from the LWC upload event; null/empty-safe.
     * @return the number of links actually created (0 when everything was already linked).
     * @throws CaptureUnavailableException when `itemId` is null.
     * @throws System.DmlException on a platform save failure.
     * @example
     * ChecklistCaptureService.linkDocumentsToItems(itemId, new List&lt;Id&gt;{ documentId });
     */
    public static Integer linkDocumentsToItems(Id itemId, List<Id> contentDocumentIds) {
        if (itemId == null) {
            throw new CaptureUnavailableException(MESSAGE_UNAVAILABLE);
        }
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) {
            return 0;
        }

        Set<Id> alreadyLinked = new Set<Id>();
        for (ContentDocumentLink link : ContentDocumentLinkSelector.selectByLinkedEntityIds(
                new Set<Id>{ itemId })) {
            alreadyLinked.add(link.ContentDocumentId);
        }

        List<ContentDocumentLink> toCreate = new List<ContentDocumentLink>();
        Set<Id> seen = new Set<Id>();
        for (Id documentId : contentDocumentIds) {
            if (documentId == null || alreadyLinked.contains(documentId) || !seen.add(documentId)) {
                continue;
            }
            toCreate.add(new ContentDocumentLink(
                ContentDocumentId = documentId,
                LinkedEntityId = itemId,
                ShareType = SHARE_TYPE_VIEWER,
                Visibility = VISIBILITY_ALL_USERS
            ));
        }
        if (toCreate.isEmpty()) {
            return 0;
        }
        Database.insert(toCreate, true, AccessLevel.USER_MODE);
        return toCreate.size();
    }

    /**
     * Resolves each item to its capture def by COORDINATE.
     *
     * 🔴 THE COORDINATE IS `(Checklist__r.Group_Letter__c, Sequence__c)`. NEVER `Subject__c`. An
     * item whose parent relationship was not selected resolves to nothing rather than falling back
     * to a text match - a silent no-capture is recoverable, a silent wrong-capture is not.
     *
     * @param items rows carrying `Sequence__c` and `Checklist__r.Group_Letter__c`; null-safe.
     * @return Map of item Id -> def, containing only items that record something; never null.
     */
    @TestVisible
    private static Map<Id, ChecklistCaptureDefProvider.CaptureDef> defsFor(
        List<Checklist_Item__c> items
    ) {
        Map<Id, ChecklistCaptureDefProvider.CaptureDef> defsByItem =
            new Map<Id, ChecklistCaptureDefProvider.CaptureDef>();
        if (items == null || items.isEmpty()) {
            return defsByItem;
        }
        for (Checklist_Item__c item : items) {
            if (item == null || item.Id == null || item.Checklist__r == null) {
                continue;
            }
            ChecklistCaptureDefProvider.CaptureDef def = ChecklistCaptureDefProvider.forCoordinate(
                item.Checklist__r.Group_Letter__c, item.Sequence__c);
            if (def != null) {
                defsByItem.put(item.Id, def);
            }
        }
        return defsByItem;
    }

    /**
     * How many documents are linked to each of the supplied items. ONE query for the whole set.
     *
     * @param itemIds `Checklist_Item__c` ids; null/empty-safe (returns an empty map, no query).
     * @return Map of item Id -> link count; items with none are ABSENT.
     */
    private static Map<Id, Integer> documentCountsByItem(Set<Id> itemIds) {
        Map<Id, Integer> counts = new Map<Id, Integer>();
        if (itemIds == null || itemIds.isEmpty()) {
            return counts;
        }
        for (ContentDocumentLink link : ContentDocumentLinkSelector.selectByLinkedEntityIds(itemIds)) {
            Integer running = counts.get(link.LinkedEntityId);
            counts.put(link.LinkedEntityId, running == null ? 1 : running + 1);
        }
        return counts;
    }

    /**
     * Whether the target record has actually RECORDED what this coordinate is about.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THIS TAKES THE DEF, NOT A FIELD NAME, AND THAT IS THE WHOLE FIX FOR THE F12/J4 DEFECT.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * The previous version was `hasValue(SObject, String)` - a pure "is it non-blank?" test. That
     * is right for Text, Currency and Date, and WRONG for a picklist carrying a default:
     * `Loan__c.Auto_Payment_Status__c` defaults to `Not Set Up`, the platform stamps it the moment
     * `LoanService.ensureFor` inserts the row, and a non-blank test therefore passed on a loan
     * nobody had touched. F12 and J4 - the two the business calls CRITICAL and most frequently
     * missed - were completable with nothing recorded from the instant any OTHER group F dialog
     * was opened, because all five share one `Loan__c`. A field name alone cannot express "which
     * values count"; the def can. Full argument at `ChecklistCaptureDefProvider.CaptureDef
     * .satisfyingValues`.
     *
     * THREE TESTS, IN ORDER, ALL OF THEM FAIL-CLOSED:
     *   1. A NULL RECORD is not a value. An unreadable or uncreatable target refuses the
     *      completion - `Loan__c` is Private OWD with an ordinary lookup and does NOT inherit the
     *      deal's sharing the way a checklist item does.
     *   2. A NULL OR BLANK VALUE is not a value. `lightning-record-edit-form` sends an emptied Text
     *      field as `''` rather than null, so a plain null check would accept a lender whose name
     *      was typed and then deleted; `String.isNotBlank` also rejects nothing but spaces.
     *   3. A VALUE OUTSIDE `satisfyingValues`, when the def declares one, is not a value.
     *
     * ⚠ THE COMPARISON IS EXACT AND CASE-SENSITIVE, deliberately. These are RESTRICTED picklist
     * values, so the platform guarantees the stored string is one of the four declared spellings -
     * a case-insensitive compare would only ever mask a typo in the allow-list constant, which is
     * the failure this method is here to prevent.
     *
     * @param record the target record; null-safe (null means "nothing recorded").
     * @param def    the coordinate's definition; a null `requiredField` means nothing is required.
     * @return true when the requirement is satisfied.
     */
    @TestVisible
    private static Boolean isRecorded(SObject record, ChecklistCaptureDefProvider.CaptureDef def) {
        if (def == null || String.isBlank(def.requiredField)) {
            return true;
        }
        if (record == null) {
            return false;
        }
        Object value = record.get(def.requiredField);
        if (value == null) {
            return false;
        }
        if (value instanceof String && String.isBlank((String) value)) {
            return false;
        }
        if (def.satisfyingValues == null || def.satisfyingValues.isEmpty()) {
            // No narrowing declared: any non-blank value counts. Correct for Text, Currency and
            // Date, and for a picklist with NO default (`Bank_Account_Type__c`).
            return true;
        }
        // Narrowed. `String.valueOf` rather than a cast: a narrowed field is always a picklist
        // today, but a cast would throw rather than refuse if that ever stopped being true, and a
        // throw here aborts a user's completion instead of explaining it.
        return def.satisfyingValues.contains(String.valueOf(value));
    }
}
