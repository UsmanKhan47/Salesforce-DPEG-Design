/**
 * Serves a Transaction's `Checklist__c` groups and their `Checklist_Item__c` rows to the Phase 3
 * LWCs (`transactionTaskGroups`, `transactionPhaseCards`, `transactionChecklistSummary`), plus the
 * two write actions those screens offer.
 *
 * layer=controller. THIN by construction: it holds no inline SOQL (all reads go through
 * `ChecklistSelector` / `ChecklistItemSelector`), no DML (that is `ChecklistItemService`), and no
 * business rule. What it does hold is DTO marshalling, which is exactly what the legacy twin
 * `TransactionTaskController.getTaskGroups` holds and is the established shape for this screen.
 *
 * ── WHY APEX AND NOT LDS, GIVEN ARCHITECTURE.md §5 IS LDS-FIRST ─────────────────────────────
 * §5 ranks LDS wire adapters, then LDS GraphQL, then imperative Apex "only when LDS cannot
 * express the query". The DISCRIMINATOR that chooses between the two checklist models IS pure
 * LDS — the LWCs read `Transaction__c.Checklist_Fanned_Out__c` with `getRecord`, no Apex
 * involved. The checklist body is the §5 case-3 exception: it is a two-object read whose child
 * filter spans a master-detail (`Checklist__r.Transaction__c`), ordered by a PARENT field
 * (`Checklist__r.Sequence__c`) so the eleven groups arrive in business order, and it is joined
 * and counted server-side so the header numbers cannot disagree with the rows underneath them.
 * A `lightning/uiGraphQLApi` version would be two flat queries re-joined and re-sorted in
 * JavaScript, and — the deciding factor — it could not be verified from source: a malformed
 * GraphQL document fails at runtime in the org with an opaque message, whereas this compiles and
 * is covered by Apex tests before it ever reaches a page.
 *
 * ── ERROR HANDLING (ARCHITECTURE.md §5) ────────────────────────────────────────────────────
 * Every `@AuraEnabled` method throws `AuraHandledException`. Three service exceptions are
 * user-ACTIONABLE and are surfaced VERBATIM, because the generic message would be actively
 * misleading advice:
 *   • `ChecklistItemPrerequisiteService.PrerequisiteNotMetException` — names the blocking step.
 *     "Refresh the page and try again" can never work; refreshing does not make the anti-fraud
 *     phone call.
 *   • `ChecklistItemService.WireVerificationException` — names the missing evidence.
 *   • `ChecklistItemService.ItemNotFoundException` — tells the user to refresh, which IS the fix.
 * Everything else gets a FIXED generic message with no platform text concatenated into it: raw
 * `DmlException` / `QueryException` text leaks field API names and validation-rule internals. The
 * detail goes to the debug log, which is admin-only.
 *
 * 🔴 A `QueryException: No such column` FROM `getChecklist` IS AN FLS DENIAL WEARING A SCHEMA
 * ERROR, NOT A BUG IN THIS CLASS. Both display selectors are `WITH USER_MODE` deliberately
 * (ARCHITECTURE.md §2), and a Metadata-API-deployed custom field arrives with ZERO
 * FieldPermissions rows for anybody, System Administrator included. If this screen shows its
 * error state for EVERYONE right after a deploy, the fix is the permission-set grant on
 * `Checklist__c` / `Checklist_Item__c`, not a mode change here.
 *
 * ⚠ NO `cacheable=true` ON THE TWO WRITE METHODS, AND `cacheable=true` ON THE READ. The read is
 * refreshed by `refreshApex` after every write, which is what makes the cache safe here; the
 * caller ALSO calls `notifyRecordUpdateAvailable` so the parent Transaction's rollup counters —
 * written by Apex behind LDS's back — reach the Path and the highlights panel.
 *
 * @see force-app/main/default/classes/ChecklistItemService.cls (all DML)
 * @see force-app/main/default/classes/TransactionTaskController.cls (the legacy Task-model twin,
 *      still live and still serving deals whose Checklist_Fanned_Out__c is false)
 * @see agent-output/design-transaction-fsd-gaps.md §6.2, §7
 */
public with sharing class ChecklistController {

    /** Fixed, generic user-safe message for a failed read. Never interpolate platform text. */
    private static final String READ_FAILURE_MESSAGE =
        'The checklist could not be loaded. Refresh the page or contact your administrator.';

    /** Fixed, generic user-safe message for an unexpected failed write. */
    private static final String WRITE_FAILURE_MESSAGE =
        'This checklist item could not be updated. Refresh the page and try again, or contact your administrator.';

    /**
     * `AuraHandledException`'s constructor argument does not reach the client on its own — the
     * message must also be set explicitly, or the LWC receives "Script-thrown exception".
     */
    private static AuraHandledException ahe(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }

    /**
     * One checklist group (`Checklist__c`) and its items.
     *
     * ⚠ MEMBER NAMES ARE THE WIRE CONTRACT. Every name below is asserted by name in the Jest
     * fixtures of the three consuming bundles. Renaming one here compiles, deploys, and then
     * renders `undefined` on the page — there is no compile-time link between an `@AuraEnabled`
     * member and the JavaScript that reads it.
     */
    public class ChecklistRow {
        /** The `Checklist__c` record Id — also the LWC's stable selection key. */
        @AuraEnabled public Id id;
        /** `A`…`J`, `H2`. */
        @AuraEnabled public String letter;
        /** Human group name, e.g. `Contract & Signatures`. */
        @AuraEnabled public String name;
        /** The owning ROLE (`Danish`, `CFO`, `Legal`…). NEVER a person — see ItemRow.ownerLabel. */
        @AuraEnabled public String ownerLabel;
        /** True for a group that only fans out under a condition (today: group F, loan deals). */
        @AuraEnabled public Boolean conditional;
        /**
         * The deal phase, byte-identical to `Transaction__c.Stage__c`: `Open Contract`,
         * `Due Diligence`, `Closing Prep`, `Post-Closing`. The LWC maps THIS to a phase, not the
         * group letter — the letter mapping is a legacy-model fallback only.
         */
        @AuraEnabled public String stage;
        /** Items in this group, in sequence order. */
        @AuraEnabled public Integer total;
        /** Items whose `Flag__c` is `Completed` OR `Verified` (`ChecklistItemDomain.isDone`). */
        @AuraEnabled public Integer complete;
        /** `complete / total` as a whole percentage; 0 when the group is empty. */
        @AuraEnabled public Integer pct;
        @AuraEnabled public List<ItemRow> items;
    }

    /** One checklist row (`Checklist_Item__c`). */
    public class ItemRow {
        @AuraEnabled public Id id;
        /** `Subject__c` VERBATIM, markers and all. Cosmetic stripping is the LWC's job. */
        @AuraEnabled public String subject;
        /**
         * ⚠ ROLE, NOT PERSON. Seeded from `Transaction_Task_Def__mdt.Owner_Label__c`; the role the
         * item is OWED BY. Never render it beside a completion date — that reads as "completed by
         * X" and is false for everyone but the one role it names (the 2026-08-28 defect). Use
         * `completedByName`.
         */
        @AuraEnabled public String ownerLabel;
        @AuraEnabled public Decimal sequence;
        /** Raw `Flag__c`: `None` | `CRITICAL` | `Verified` | `Completed`. */
        @AuraEnabled public String flag;
        /** `ChecklistItemDomain.isDone(flag)` — TRUE for `Completed` **and** `Verified`. */
        @AuraEnabled public Boolean done;
        /**
         * 🔴 THE IMMUTABLE SEVERITY, AND THE FIELD THAT RETIRES THE SUBJECT REGEX. Read from
         * `Is_Critical__c`, never derived from the subject text. See `getChecklist`.
         */
        @AuraEnabled public Boolean isCritical;
        /**
         * 🔴 THE ANTI-FRAUD MARKER, AND THE FIELD THAT RETIRES `contains('anti-fraud')`. Read from
         * `Is_Wire_Verification__c`. This is what `Transaction__c.Wire_Open_Risks__c` counts.
         */
        @AuraEnabled public Boolean isWireVerification;
        /** Whether the verbal verification is on file. */
        @AuraEnabled public Boolean verifyComplete;
        @AuraEnabled public String verifiedByName;
        @AuraEnabled public String phone;
        @AuraEnabled public Datetime verifiedAt;
        @AuraEnabled public String comment;
        @AuraEnabled public Date dueDate;
        /**
         * The REAL completer — `Completed_By__r.Name`, stamped at the moment of transition by
         * `ChecklistItemDomain.stampCompletion` and never recomputed. This is what replaces the
         * `LastModifiedBy` approximation the Task model was stuck with.
         */
        @AuraEnabled public String completedByName;
        @AuraEnabled public Datetime completedDateTime;
        /**
         * TRUE when this item has an unmet prerequisite and the wire-fraud gate would refuse it.
         * Rendered as a disabled row with an explanation, so the control is VISIBLE rather than a
         * surprise refusal after the user has already typed a comment.
         * ⚠ ADVISORY ONLY. The enforcement is the before-update trigger plus the
         * `Prerequisite_Must_Be_Met_To_Complete` validation rule; this flag just tells the truth
         * earlier. Never treat a false here as permission to skip the server check.
         */
        @AuraEnabled public Boolean blocked;
    }

    /**
     * Every checklist group on a Transaction, with its items, ordered by group sequence then item
     * sequence.
     *
     * 🔴 COUNTS ARE COMPUTED FROM THE ITEMS THIS METHOD ACTUALLY RETURNS, **NOT** READ FROM
     * `Checklist__c.Items_Total__c` / `Items_Complete__c` / `Pct_Complete__c`. Those three are
     * Apex-written by `ChecklistRollupService` after the item trigger fires, so between a
     * completion and its rollup they can lag by one. Reading them here would let a single screen
     * contradict itself — a header reading "3 of 10" above a list showing four ticked rows — which
     * is the specific kind of wrongness that destroys trust in a checklist. The stored fields
     * remain the source for reports and for `Transaction__c`'s counters; they are simply not what
     * this screen renders.
     *
     * 🔴 `isCritical` AND `isWireVerification` COME FROM THE BOOLEAN FIELDS. There is no subject
     * parsing anywhere in this class, and none must be added. The legacy model derives the same
     * two facts from a regex on `Task.Subject` because `Task` carries no such fields — that parse
     * lives in the legacy path of `c/utilsTransactionChecklist` and nowhere else.
     *
     * ⚠ RETURNS AN EMPTY LIST FOR A DEAL WITH NO CHECKLIST, WHICH IS NOT AN ERROR. A Transaction
     * whose `Checklist_Fanned_Out__c` is true but which has no groups is a real, visible state
     * (a fan-out that failed, or a deal fanned out before a group existed), and the LWC renders it
     * as an explicit empty message rather than blank space.
     *
     * ⚠ A group with zero items is DROPPED, matching the legacy twin. An empty conditional group
     * (e.g. F on a no-loan deal) would otherwise render a `0 / 0` shell that reads as broken.
     *
     * @param transactionId the `Transaction__c` whose checklist to load.
     * @return the groups, ordered; never null.
     * @throws AuraHandledException with a fixed generic message on any failure.
     */
    @AuraEnabled(cacheable=true)
    public static List<ChecklistRow> getChecklist(Id transactionId) {
        try {
            if (transactionId == null) {
                return new List<ChecklistRow>();
            }
            Set<Id> dealIds = new Set<Id>{ transactionId };

            List<Checklist__c> checklists = ChecklistSelector.selectForDisplayByTransactionIds(dealIds);
            if (checklists.isEmpty()) {
                return new List<ChecklistRow>();
            }

            Map<Id, ChecklistRow> rowByChecklistId = new Map<Id, ChecklistRow>();
            List<ChecklistRow> ordered = new List<ChecklistRow>();
            for (Checklist__c checklist : checklists) {
                ChecklistRow row = new ChecklistRow();
                row.id = checklist.Id;
                row.letter = checklist.Group_Letter__c;
                row.name = checklist.Group_Name__c;
                row.ownerLabel = checklist.Owner_Label__c;
                row.conditional = checklist.Is_Conditional__c == true;
                row.stage = checklist.Stage__c;
                row.items = new List<ItemRow>();
                row.total = 0;
                row.complete = 0;
                row.pct = 0;
                rowByChecklistId.put(checklist.Id, row);
                ordered.add(row);
            }

            for (Checklist_Item__c item : ChecklistItemSelector.selectForDisplayByTransactionIds(dealIds)) {
                ChecklistRow row = rowByChecklistId.get(item.Checklist__c);
                if (row == null) {
                    // Cannot happen through the two selectors above (same filter, same deal), but
                    // a null-deref here would take the whole screen down for one orphan row.
                    continue;
                }
                ItemRow itemRow = new ItemRow();
                itemRow.id = item.Id;
                itemRow.subject = item.Subject__c;
                itemRow.ownerLabel = item.Owner_Label__c;
                itemRow.sequence = item.Sequence__c;
                itemRow.flag = item.Flag__c;
                itemRow.done = ChecklistItemDomain.isDone(item.Flag__c);
                itemRow.isCritical = item.Is_Critical__c == true;
                itemRow.isWireVerification = item.Is_Wire_Verification__c == true;
                itemRow.verifyComplete = item.Verbal_Verification_Completed__c == true;
                itemRow.verifiedByName = item.Verified_By_Name__c;
                itemRow.phone = item.Verification_Phone__c;
                itemRow.verifiedAt = item.Verified_DateTime__c;
                itemRow.comment = item.Comment__c;
                itemRow.dueDate = item.Due_Date__c;
                // Null-guarded: a sharing-restricted reader gets a null Completed_By__r back even
                // though the lookup id is populated.
                itemRow.completedByName = item.Completed_By__r != null ? item.Completed_By__r.Name : null;
                itemRow.completedDateTime = item.Completed_DateTime__c;
                itemRow.blocked = item.Blocked_By__c != null && item.Is_Prerequisite_Met__c != true;
                row.items.add(itemRow);
                row.total++;
                if (itemRow.done) {
                    row.complete++;
                }
            }

            List<ChecklistRow> result = new List<ChecklistRow>();
            for (ChecklistRow row : ordered) {
                if (row.total == 0) {
                    continue;
                }
                row.pct = Integer.valueOf(Math.round(100.0 * row.complete / row.total));
                result.add(row);
            }
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'ChecklistController.getChecklist on ' + transactionId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Completes one checklist item, optionally persisting the comment captured in the confirm
     * dialog.
     *
     * @param itemId  the `Checklist_Item__c` to complete.
     * @param comment optional free text; blank leaves the existing comment untouched.
     * @throws AuraHandledException — verbatim for the three user-actionable service exceptions,
     *         generic for anything else.
     */
    @AuraEnabled
    public static void completeItem(Id itemId, String comment) {
        try {
            ChecklistItemService.complete(new List<ChecklistItemService.CompletionRequest>{
                new ChecklistItemService.CompletionRequest(itemId, comment)
            });
        } catch (ChecklistItemPrerequisiteService.PrerequisiteNotMetException e) {
            // Names the blocking step. The generic message would tell the user to refresh, which
            // can never complete an anti-fraud phone call.
            throw ahe(e.getMessage());
        } catch (ChecklistItemService.WireVerificationException e) {
            throw ahe(e.getMessage());
        } catch (ChecklistItemService.ItemNotFoundException e) {
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'ChecklistController.completeItem on ' + itemId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    /**
     * Records the wire-fraud verbal verification and closes the item (DPEG brief Section 06).
     *
     * @param itemId         the wire-verification `Checklist_Item__c`.
     * @param verifiedByName the confirmer's name (required).
     * @param phone          the independently looked-up number called (required).
     * @param comment        optional verifier comments, logged above the standard note.
     * @throws AuraHandledException — verbatim for the user-actionable service exceptions, generic
     *         for anything else.
     */
    @AuraEnabled
    public static void recordWireVerification(Id itemId, String verifiedByName, String phone, String comment) {
        try {
            ChecklistItemService.recordWireVerification(
                new List<ChecklistItemService.WireVerificationRequest>{
                    new ChecklistItemService.WireVerificationRequest(itemId, verifiedByName, phone, comment)
                }
            );
        } catch (ChecklistItemService.WireVerificationException e) {
            throw ahe(e.getMessage());
        } catch (ChecklistItemService.ItemNotFoundException e) {
            throw ahe(e.getMessage());
        } catch (ChecklistItemPrerequisiteService.PrerequisiteNotMetException e) {
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'ChecklistController.recordWireVerification on ' + itemId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
