/**
 * The Phase 4 migration's PURE half: projects a deal's legacy `Task` checklist onto the
 * `Checklist__c` / `Checklist_Item__c` model, and reconciles the two.
 *
 * layer=domain. **ZERO SOQL, ZERO DML, ZERO `Limits` reads.** Everything it needs is passed in.
 * That is not house style for its own sake — it is what lets ONE comparison serve both callers:
 * `ChecklistMigrationService` runs it BEFORE any DML as a per-deal gate, and
 * `ChecklistMigrationAuditService` runs it AFTER, against the persisted rows, as the M2 report.
 * Two mechanisms sharing one predicate cannot drift; two implementations would, silently.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 M2 IS A MECHANISM HERE, NOT A CHECK. A DEAL THAT DOES NOT RECONCILE IS NOT MIGRATED.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Design §7 left the reconciliation as a report run between M1 and M3 — which, as the Phase 4
 * brief put it, is "a check, not a mechanism". It can be both, because the comparison is
 * computable BEFORE any row is written: the new rows are projected from the deal's own `Task`
 * rows, and the legacy counters are recomputable from those same rows in the same transaction.
 * So `project` returns `isReconciled`, and `ChecklistMigrationService` inserts NOTHING for a deal
 * that comes back false.
 * The consequence is what makes a disagreement LOUD in an async job that has no UI: **the deal
 * visibly does not move.** `Checklist_Fanned_Out__c = false` after a run is a queryable,
 * unambiguous "this deal was refused", and the audit service then explains each one by name.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 FOUR RULES THAT LOOK LIKE DETAILS AND ARE NOT.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 1. THE COORDINATE IS `Task_Group__c` LETTER + `Task_Sequence__c`. NEVER THE SUBJECT.
 *    `Task_Group__c` holds `B. Earnest Money Wire`, so the letter is everything before the
 *    first dot — which also handles `H2`, the one two-character letter, with no special case. A
 *    subject-based mapping is the trap design §2.8 documents: a bare `contains('critical')`
 *    wrongly flags A4 (`Receive critical dates...`) and A5 (`Log critical dates...`). `Subject`
 *    IS read here, for exactly one purpose — the legacy `anti-fraud` parse, as one half of the
 *    RISK 1 canary (rule 3). Nothing maps on it.
 * 2. BUILD FROM THE TASKS THAT EXIST, NEVER FROM THE 82-ROW DEFINITION LIST. Group F is absent
 *    on a no-loan deal, so `Tasks_Total__c` is per-Transaction and not always 82
 *    (`TaskRollupService`'s header is emphatic). Projecting from the definitions would give every
 *    no-loan deal 12 phantom incomplete items. A definition with no Task is reported
 *    **ADVISORY, not blocking** — see `DEFINITION_WITHOUT_TASK` below for why.
 * 3. THE LEGACY PREDICATES ARE COPIED, NOT IMPROVED. Open-wire is `Subject` contains
 *    `anti-fraud` AND `Verbal_Verification_Completed__c != true`, which is
 *    `TaskRollupService.recalc` line for line; done-ness is `ChecklistItemDomain.isDone`, which
 *    is `Completed` **OR** `Verified`. A reconciliation that quietly improved on the old
 *    predicate would make the comparison meaningless — which is precisely why
 *    `ChecklistRollupService`'s open-wire predicate was built to mirror the legacy one rather
 *    than to use `isDone`. Changing either is a decision to take WITH the reconciliation in
 *    hand, not while writing it.
 * 4. `Blocked_By__c` IS NEVER SET ON A PROJECTED ITEM. It is carried as a COORDINATE
 *    (`blockedByLetter` / `blockedBySequence`) for the service's second pass. Inserting an
 *    already-`Completed` item that also carries a link is refused by
 *    `Prerequisite_Must_Be_Met_To_Complete`'s `ISNEW()` arm reading the value
 *    `ChecklistItemPrerequisiteService.clampOnInsert` forced to false — and with
 *    `allOrNone = false` that would SILENTLY DROP exactly the completed B3/I8 rows. The
 *    two-pass shape is not a workaround; it is what `ChecklistFanoutService.fanOutNow` and
 *    `scripts/backfill-task-blocked-by.apex` both already do.
 *
 * ⚠ NO PERCENTAGES ANYWHERE IN THIS CLASS, BY DESIGN. Every finding names a deal, a check, and
 * where applicable a coordinate. "97% agreement" is unactionable and hides which 3%.
 *
 * @see force-app/main/default/classes/ChecklistMigrationService.cls
 * @see force-app/main/default/classes/ChecklistMigrationAuditService.cls
 * @see agent-output/phase4-migration-design.md §0.3, §3
 */
public with sharing class ChecklistMigrationDomain {

    /** Blocking findings refuse the deal; advisory findings are reported and refuse nothing. */
    public enum Severity { BLOCKING, ADVISORY }

    /** `Flag__c` written for a Task that is closed. The Task model has no `Verified` state. */
    @TestVisible
    private static final String FLAG_FOR_CLOSED_TASK = ChecklistItemDomain.FLAG_COMPLETED;

    /** `Checklist_Item__c.Comment__c` is a LongTextArea of 4,000. Verified in the field metadata. */
    @TestVisible
    private static final Integer COMMENT_MAX_LENGTH = 4000;

    /** Reserved so the marker itself can never push the value back over the limit. */
    private static final String TRUNCATION_MARKER = ' [truncated by checklist migration]';

    /**
     * Clips a `Task.Description` (32,000) to fit `Comment__c` (4,000), appending a visible marker.
     *
     * The marker length is subtracted from the budget rather than appended afterwards - appending
     * to an already-maximal string is how a truncation helper ends up one character too long and
     * throws the very exception it was written to prevent.
     *
     * @param description The legacy note; null- and short-safe (returned unchanged).
     * @return A value guaranteed to fit, marked when anything was removed.
     */
    @TestVisible
    private static String truncateComment(String description) {
        if (description == null || description.length() <= COMMENT_MAX_LENGTH) {
            return description;
        }
        Integer budget = COMMENT_MAX_LENGTH - TRUNCATION_MARKER.length();
        return description.substring(0, budget) + TRUNCATION_MARKER;
    }

    /**
     * One finding. `coordinate` is blank for deal-level checks and carries e.g. `B2` or `H2:5`
     * for per-item ones.
     */
    public class Discrepancy {
        /** BLOCKING or ADVISORY. Named `impact` because a field named `severity` would collide
         *  case-insensitively with the `Severity` enum and make `Severity.BLOCKING` unresolvable. */
        public Severity impact;
        /** Stable check name, e.g. `COUNTER_MISMATCH`. Greppable; do not localise. */
        public String checkName;
        /** `<letter><sequence>` when the finding is about one item; blank otherwise. */
        public String coordinate;
        /** The legacy model's value, rendered. */
        public String taskValue;
        /** The checklist model's value, rendered. */
        public String itemValue;

        /**
         * @param impact     BLOCKING or ADVISORY.
         * @param checkName  Stable check name.
         * @param coordinate Item coordinate, or null/blank for a deal-level finding.
         * @param taskValue  Legacy value.
         * @param itemValue  Checklist value.
         */
        public Discrepancy(Severity impact, String checkName, String coordinate,
                String taskValue, String itemValue) {
            this.impact = impact;
            this.checkName = checkName;
            this.coordinate = coordinate == null ? '' : coordinate;
            this.taskValue = taskValue == null ? '' : taskValue;
            this.itemValue = itemValue == null ? '' : itemValue;
        }
    }

    /** The four counters, computed identically from either model. */
    public class Counters {
        /** Item/Task count. */
        public Integer total = 0;
        /** Done count. */
        public Integer complete = 0;
        /** Open and past due. */
        public Integer overdue = 0;
        /** Wire-verification rows whose verbal verification is not recorded. */
        public Integer wireOpen = 0;
    }

    /**
     * A checklist item reduced to the fields the comparison reads, so the SAME comparison runs
     * against a projected (unsaved, parentless) item and a persisted one.
     */
    public class ItemView {
        /** Group letter, upper-cased. */
        public String letter;
        /** Sequence within the group. */
        public Integer sequence;
        /** `ChecklistItemDomain.isDone(Flag__c)`. */
        public Boolean done = false;
        /** `Is_Critical__c`. */
        public Boolean critical = false;
        /** `Is_Wire_Verification__c`. */
        public Boolean wireVerification = false;
        /** `Verbal_Verification_Completed__c`. */
        public Boolean verbal = false;
        /** `Due_Date__c`. */
        public Date dueDate;
        /** Whether `Blocked_By__c` is populated. */
        public Boolean hasPrerequisiteLink = false;
    }

    /** An unsaved checklist plus the items that belong under it. */
    public class PendingChecklist {
        /** The unsaved `Checklist__c`. */
        public Checklist__c record;
        /** Group letter, upper-cased. */
        public String letter;
        /** Items under this checklist, in sequence order. */
        public List<PendingItem> items = new List<PendingItem>();
    }

    /** An unsaved item plus the coordinates the service needs after insert. */
    public class PendingItem {
        /** The unsaved `Checklist_Item__c`, with `Blocked_By__c` DELIBERATELY BLANK (rule 4). */
        public Checklist_Item__c record;
        /**
         * The deal this item belongs to.
         * 🔴 CARRIED HERE RATHER THAN TRAVERSED. An UNSAVED sObject has no populated
         * `Checklist__r`, so `record.Checklist__r.Transaction__c` is a null dereference at
         * projection time — and the service builds its cross-deal prerequisite index from
         * exactly this value, before any insert.
         */
        public Id dealId;
        /** Its own group letter. */
        public String letter;
        /** Its own sequence. */
        public Integer sequence;
        /** Prerequisite's group letter, or null when this item is not gated. */
        public String blockedByLetter;
        /** Prerequisite's sequence, or null when this item is not gated. */
        public Integer blockedBySequence;
    }

    /** Everything one deal's projection produced. */
    public class Projection {
        /** The deal. */
        public Id transactionId;
        /** Unsaved checklists, ordered by group sequence. */
        public List<PendingChecklist> checklists = new List<PendingChecklist>();
        /** Counters derived from the projected items. */
        public Counters counters = new Counters();
        /** Every finding, blocking and advisory. */
        public List<Discrepancy> discrepancies = new List<Discrepancy>();
        /** False when any finding is BLOCKING. The service refuses the deal on false. */
        public Boolean isReconciled = true;
        /** Total projected items, i.e. what `Tasks_Total__c` becomes. */
        public Integer itemCount = 0;
    }

    /**
     * Projects one deal's Tasks onto the checklist model AND reconciles the result against them.
     *
     * ⚠ TAKES THE DEAL'S STORED COUNTERS AS A `Counters`, NOT THE `Transaction__c` ITSELF. The
     * obvious signature would read `deal.Tasks_Total__c` here, and this class is called with
     * Transactions loaded by more than one selector — reading a field a given caller did not
     * SELECT throws `System.SObjectException` at runtime, not at compile time. Projecting the
     * four values at the call site makes the dependency explicit and the domain unqueryable.
     *
     * @param transactionId  The deal being projected.
     * @param storedCounters Its stored counters, for the ADVISORY drift check. Null-safe.
     * @param tasks     That deal's checklist Tasks (`Task_Group__c` populated). Never null.
     * @param groupDefs `Task_Group_Def__mdt` rows, keyed internally by `Letter__c`.
     * @param itemDefs  `Transaction_Task_Def__mdt` rows, keyed internally by letter + sequence.
     * @param today     Injected so a projection and its assertions cannot straddle midnight.
     * @return The projection, with `isReconciled` false when anything blocking was found.
     * @example
     * Projection p = ChecklistMigrationDomain.project(
     *     deal.Id, stored, tasks, groupDefs, itemDefs, Date.today());
     */
    public static Projection project(
        Id transactionId,
        Counters storedCounters,
        List<Task> tasks,
        List<Task_Group_Def__mdt> groupDefs,
        List<Transaction_Task_Def__mdt> itemDefs,
        Date today
    ) {
        Projection projection = new Projection();
        projection.transactionId = transactionId;
        if (transactionId == null) {
            add(projection, Severity.BLOCKING, 'NOT_VISIBLE', null, 'requested', 'no row returned');
            return projection;
        }
        if (tasks == null || tasks.isEmpty()) {
            add(projection, Severity.BLOCKING, 'NO_CHECKLIST_TASKS', null, '0', 'nothing to migrate');
            return projection;
        }

        Map<String, Task_Group_Def__mdt> groupByLetter = indexGroups(groupDefs);
        Map<String, Transaction_Task_Def__mdt> defByCoordinate = indexDefs(itemDefs);

        // ── Pass A: bucket the Tasks by coordinate, refusing anything ambiguous ────────────
        Map<String, Task> taskByCoordinate = new Map<String, Task>();
        List<String> letterOrder = new List<String>();
        Set<String> seenLetters = new Set<String>();
        for (Task legacyTask : tasks) {
            String letter = letterOf(legacyTask.Task_Group__c);
            if (String.isBlank(letter) || legacyTask.Task_Sequence__c == null) {
                add(projection, Severity.BLOCKING, 'UNMAPPABLE_TASK', null,
                    String.valueOf(legacyTask.Task_Group__c), 'letter or sequence missing');
                continue;
            }
            String coordinate = coordinateOf(letter, Integer.valueOf(legacyTask.Task_Sequence__c));
            if (taskByCoordinate.containsKey(coordinate)) {
                add(projection, Severity.BLOCKING, 'COORDINATE_DUPLICATE', coordinate, '2 or more', '');
                continue;
            }
            taskByCoordinate.put(coordinate, legacyTask);
            if (seenLetters.add(letter)) {
                letterOrder.add(letter);
            }
        }

        // ── Pass B: one checklist per letter present, from the group definition ────────────
        Map<String, PendingChecklist> checklistByLetter = new Map<String, PendingChecklist>();
        for (String letter : letterOrder) {
            Task_Group_Def__mdt groupDef = groupByLetter.get(letter);
            if (groupDef == null) {
                add(projection, Severity.BLOCKING, 'NO_GROUP_DEFINITION', letter, letter,
                    'no Task_Group_Def__mdt row');
                continue;
            }
            PendingChecklist pending = new PendingChecklist();
            pending.letter = letter;
            pending.record = new Checklist__c(
                Transaction__c = transactionId,
                Group_Letter__c = groupDef.Letter__c,
                Group_Name__c = groupDef.Group_Name__c,
                Owner_Label__c = groupDef.Owner_Label__c,
                Sequence__c = groupDef.Sequence__c,
                Stage__c = groupDef.Stage__c,
                Is_Conditional__c = (groupDef.Conditional__c == true),
                Items_Total__c = 0,
                Items_Complete__c = 0
            );
            checklistByLetter.put(letter, pending);
            projection.checklists.add(pending);
        }

        // ── Pass C: one item per Task, from the item definition + the Task's own history ───
        List<ItemView> views = new List<ItemView>();
        for (String coordinate : sortedKeys(taskByCoordinate.keySet())) {
            Task legacyTask = taskByCoordinate.get(coordinate);
            String letter = letterOf(legacyTask.Task_Group__c);
            PendingChecklist parent = checklistByLetter.get(letter);
            if (parent == null) {
                continue; // its group already produced a blocking NO_GROUP_DEFINITION
            }
            Transaction_Task_Def__mdt itemDef = defByCoordinate.get(coordinate);
            if (itemDef == null) {
                // Refused, not defaulted. Building the item anyway would give it
                // Is_Critical__c = false and Is_Wire_Verification__c = false — i.e. a wire item
                // silently losing the flag Wire_Open_Risks__c counts. That is RISK 1 reappearing
                // inside the migration itself.
                add(projection, Severity.BLOCKING, 'NO_DEFINITION', coordinate,
                    String.valueOf(legacyTask.Subject), 'no Transaction_Task_Def__mdt row');
                continue;
            }
            PendingItem pending = buildItem(legacyTask, itemDef, parent, letter, transactionId);
            parent.items.add(pending);
            views.add(viewOfPending(pending));
            if (legacyTask.Description != null
                    && legacyTask.Description.length() > COMMENT_MAX_LENGTH) {
                // ADVISORY, and the reasoning is at `truncateComment`: the note was clipped to fit
                // Comment__c, the clipped value carries a visible marker, and refusing the deal
                // over an unfixable field-length difference would strand it on the Task model.
                add(projection, Severity.ADVISORY, 'COMMENT_TRUNCATED', coordinate,
                    String.valueOf(legacyTask.Description.length()) + ' chars',
                    String.valueOf(COMMENT_MAX_LENGTH) + ' chars max');
            }
            if (itemDef.Subject__c != legacyTask.Subject) {
                add(projection, Severity.ADVISORY, 'SUBJECT_DRIFT', coordinate,
                    String.valueOf(legacyTask.Subject), String.valueOf(itemDef.Subject__c));
            }
        }

        // A definition with no Task. ADVISORY ON PURPOSE, and this is a real judgement call:
        // rule 2 says the migration is faithful to the Tasks that EXIST, so a Task somebody
        // deleted is a fact about the deal, not a defect. Making this blocking would refuse
        // every deal anyone has ever tidied. It is still named, per coordinate, so it cannot
        // hide.
        for (String letter : letterOrder) {
            if (!checklistByLetter.containsKey(letter)) {
                continue;
            }
            for (Transaction_Task_Def__mdt itemDef : itemDefs) {
                if (upper(itemDef.Group_Letter__c) != letter || itemDef.Sequence__c == null) {
                    continue;
                }
                String coordinate = coordinateOf(letter, Integer.valueOf(itemDef.Sequence__c));
                if (!taskByCoordinate.containsKey(coordinate)) {
                    add(projection, Severity.ADVISORY, 'DEFINITION_WITHOUT_TASK', coordinate,
                        'absent', String.valueOf(itemDef.Subject__c));
                }
            }
        }

        // ── Pass D: group counters, deal counters, and the reconciliation ──────────────────
        for (PendingChecklist pending : projection.checklists) {
            Integer done = 0;
            for (PendingItem item : pending.items) {
                if (ChecklistItemDomain.isDone(item.record.Flag__c)) {
                    done++;
                }
            }
            pending.record.Items_Total__c = pending.items.size();
            pending.record.Items_Complete__c = done;
            projection.itemCount += pending.items.size();
        }
        projection.counters = countItems(views, today);
        projection.discrepancies.addAll(
            compare(fromTasks(tasks, today), projection.counters, views,
                    taskByCoordinate, defByCoordinate, storedCounters));

        for (Discrepancy finding : projection.discrepancies) {
            if (finding.impact == Severity.BLOCKING) {
                projection.isReconciled = false;
                break;
            }
        }
        return projection;
    }

    /**
     * Reconciles a set of legacy Tasks against a set of item views — the SINGLE comparison,
     * used by the pre-DML gate (views projected) and by the M2 audit (views persisted).
     *
     * @param taskCounters   Counters derived from the Tasks.
     * @param itemCounters   Counters derived from the item views.
     * @param views          The checklist side.
     * @param taskByCoordinate The legacy side, indexed.
     * @param defByCoordinate  Definitions, indexed.
     * @param storedCounters The deal's stored counters, for the advisory drift check. Null-safe.
     * @return Every finding; empty when the two models agree.
     */
    public static List<Discrepancy> compare(
        Counters taskCounters,
        Counters itemCounters,
        List<ItemView> views,
        Map<String, Task> taskByCoordinate,
        Map<String, Transaction_Task_Def__mdt> defByCoordinate,
        Counters storedCounters
    ) {
        List<Discrepancy> findings = new List<Discrepancy>();
        Map<String, ItemView> viewByCoordinate = new Map<String, ItemView>();
        for (ItemView view : views) {
            String coordinate = coordinateOf(view.letter, view.sequence);
            if (viewByCoordinate.containsKey(coordinate)) {
                findings.add(new Discrepancy(Severity.BLOCKING, 'COORDINATE_DUPLICATE',
                    coordinate, '', '2 or more items'));
                continue;
            }
            viewByCoordinate.put(coordinate, view);
        }

        Integer expectedWireItems = 0;
        Integer expectedCriticalItems = 0;
        List<String> expectedWireCoordinates = new List<String>();

        for (String coordinate : sortedKeys(taskByCoordinate.keySet())) {
            Task legacyTask = taskByCoordinate.get(coordinate);
            Transaction_Task_Def__mdt itemDef = defByCoordinate.get(coordinate);
            ItemView view = viewByCoordinate.get(coordinate);
            if (view == null) {
                findings.add(new Discrepancy(Severity.BLOCKING, 'COORDINATE_MISSING_ITEM',
                    coordinate, String.valueOf(legacyTask.Subject), 'no item'));
                continue;
            }
            if (itemDef == null) {
                // 🔴 W6: THIS RUNS IN **PERSISTED** MODE TOO, WHICH IS THE MODE THAT GATES
                // CUTOVER. `project` emits NO_DEFINITION for the M1 gate, but `project` is only
                // reached for an UN-migrated deal. Without this branch, a CMDT row deleted or
                // re-sequenced BETWEEN M1 and M2 would leave an already-migrated deal reading
                // CLEAN - the reconciliation would silently stop checking severity and wire flags
                // for that coordinate while reporting nothing wrong. Blocking, for the same reason
                // it is blocking in `project`: a missing definition is how a wire item loses the
                // flag `Wire_Open_Risks__c` counts.
                findings.add(new Discrepancy(Severity.BLOCKING, 'NO_DEFINITION', coordinate,
                    String.valueOf(legacyTask.Subject), 'no Transaction_Task_Def__mdt row'));
            }
            if (itemDef != null && itemDef.Is_Wire_Verification__c == true) {
                expectedWireItems++;
                expectedWireCoordinates.add(coordinate);
            }
            if (itemDef != null && itemDef.Is_Critical__c == true) {
                expectedCriticalItems++;
            }
            if ((legacyTask.IsClosed == true) != (view.done == true)) {
                findings.add(new Discrepancy(Severity.BLOCKING, 'STATUS_MISMATCH', coordinate,
                    'closed=' + legacyTask.IsClosed, 'done=' + view.done));
            }
            // THE RISK 1 CANARY: the legacy string parse against the boolean field, on the SAME
            // row. This is the one check that proves Is_Wire_Verification__c may be trusted
            // before Wire_Open_Risks__c stops being computed from the subject.
            if (isLegacyWireTask(legacyTask) != (view.wireVerification == true)) {
                findings.add(new Discrepancy(Severity.BLOCKING, 'WIRE_FLAG_MISMATCH', coordinate,
                    'anti-fraud=' + isLegacyWireTask(legacyTask),
                    'Is_Wire_Verification__c=' + view.wireVerification));
            }
            if ((legacyTask.Verbal_Verification_Completed__c == true) != (view.verbal == true)) {
                findings.add(new Discrepancy(Severity.BLOCKING, 'VERBAL_MISMATCH', coordinate,
                    String.valueOf(legacyTask.Verbal_Verification_Completed__c),
                    String.valueOf(view.verbal)));
            }
            if (legacyTask.ActivityDate != view.dueDate) {
                findings.add(new Discrepancy(Severity.BLOCKING, 'DUE_DATE_MISMATCH', coordinate,
                    String.valueOf(legacyTask.ActivityDate), String.valueOf(view.dueDate)));
            }
            if (itemDef != null && itemDef.Blocked_By_Sequence__c != null
                    && view.hasPrerequisiteLink != true) {
                findings.add(new Discrepancy(Severity.BLOCKING, 'PREREQ_UNRESOLVED', coordinate,
                    'definition declares a prerequisite', 'Blocked_By__c is blank'));
            }
        }
        for (String coordinate : sortedKeys(viewByCoordinate.keySet())) {
            if (!taskByCoordinate.containsKey(coordinate)) {
                findings.add(new Discrepancy(Severity.BLOCKING, 'COORDINATE_MISSING_TASK',
                    coordinate, 'no Task', 'item present'));
            }
        }

        addCounterFindings(findings, taskCounters, itemCounters);

        Integer actualWireItems = 0;
        Integer actualCriticalItems = 0;
        for (ItemView view : views) {
            if (view.wireVerification == true) {
                actualWireItems++;
            }
            if (view.critical == true) {
                actualCriticalItems++;
            }
        }
        // 🔴 W7 - CHECK 9 NAMES THE COORDINATES, AND THE ACTUAL ONES AS WELL AS THE EXPECTED.
        // Design §3 row 9 requires both coordinates on the line. Reporting only a COUNT makes the
        // one finding that matters most unactionable: "expected 2, got 1" does not say WHICH wire
        // step lost its flag, and B2 (the earnest-money wire) and I7 (the CLOSING wire) are not
        // interchangeable - I7 is the higher-value one and the one design §2.8 records as having
        // silently lost its red flag once already.
        List<String> actualWireCoordinates = new List<String>();
        for (ItemView view : views) {
            if (view.wireVerification == true) {
                String coordinate = coordinateOf(view.letter, view.sequence);
                if (coordinate != null) {
                    actualWireCoordinates.add(coordinate);
                }
            }
        }
        actualWireCoordinates.sort();
        if (actualWireItems != expectedWireItems) {
            findings.add(new Discrepancy(Severity.BLOCKING, 'WIRE_ITEM_COUNT',
                'expected[' + String.join(expectedWireCoordinates, ',') + ']'
                    + ' actual[' + String.join(actualWireCoordinates, ',') + ']',
                String.valueOf(expectedWireItems), String.valueOf(actualWireItems)));
        }
        if (expectedWireItems == 0) {
            // Structural, not arithmetic: with no wire-verification definitions matching this
            // deal, Wire_Open_Risks__c is zero on BOTH models and the agreement is vacuous.
            // Almost always means scripts/load-transaction-task-defs.apex has not been re-run.
            findings.add(new Discrepancy(Severity.BLOCKING, 'WIRE_ITEM_COUNT', '',
                'no Is_Wire_Verification__c definitions matched this deal',
                'Wire_Open_Risks__c would be structurally zero - run the CMDT loader'));
        }
        if (actualCriticalItems != expectedCriticalItems) {
            // ⚠ DERIVED, NOT 4. Design §7 says "assert the CRITICAL count is 4 per deal", which
            // is wrong for a no-loan deal: F12 lives in conditional group F, so such a deal
            // legitimately has 3. A hardcoded 4 would red-line every no-loan deal in the org.
            findings.add(new Discrepancy(Severity.BLOCKING, 'CRITICAL_COUNT', '',
                String.valueOf(expectedCriticalItems), String.valueOf(actualCriticalItems)));
        }
        addStoredDriftFindings(findings, storedCounters, taskCounters);
        return findings;
    }

    /**
     * The four counters computed from legacy Tasks, using `TaskRollupService.recalc`'s
     * predicates verbatim (rule 3) — including its else-if, so `overdue` counts OPEN past-due
     * rows only.
     *
     * @param tasks The deal's checklist Tasks.
     * @param today Injected today.
     * @return Counters.
     */
    public static Counters fromTasks(List<Task> tasks, Date today) {
        Counters counters = new Counters();
        if (tasks == null) {
            return counters;
        }
        for (Task legacyTask : tasks) {
            counters.total++;
            if (legacyTask.IsClosed) {
                counters.complete++;
            } else if (legacyTask.ActivityDate != null && legacyTask.ActivityDate < today) {
                counters.overdue++;
            }
            if (isLegacyWireTask(legacyTask)
                    && legacyTask.Verbal_Verification_Completed__c != true) {
                counters.wireOpen++;
            }
        }
        return counters;
    }

    /**
     * The four counters computed from item views, using `ChecklistRollupService.recalc`'s
     * predicates verbatim.
     *
     * @param views The checklist side.
     * @param today Injected today.
     * @return Counters.
     */
    public static Counters countItems(List<ItemView> views, Date today) {
        Counters counters = new Counters();
        if (views == null) {
            return counters;
        }
        for (ItemView view : views) {
            counters.total++;
            if (view.done == true) {
                counters.complete++;
            } else if (view.dueDate != null && view.dueDate < today) {
                counters.overdue++;
            }
            if (view.wireVerification == true && view.verbal != true) {
                counters.wireOpen++;
            }
        }
        return counters;
    }

    /**
     * Reduces a persisted item to the comparison view. Requires `Checklist__r.Group_Letter__c`.
     *
     * @param item A persisted `Checklist_Item__c`.
     * @return Its view.
     */
    public static ItemView viewOf(Checklist_Item__c item) {
        ItemView view = new ItemView();
        view.letter = item.Checklist__r == null
            ? null
            : upper(item.Checklist__r.Group_Letter__c);
        view.sequence = item.Sequence__c == null ? null : Integer.valueOf(item.Sequence__c);
        view.done = ChecklistItemDomain.isDone(item.Flag__c);
        view.critical = (item.Is_Critical__c == true);
        view.wireVerification = (item.Is_Wire_Verification__c == true);
        view.verbal = (item.Verbal_Verification_Completed__c == true);
        view.dueDate = item.Due_Date__c;
        view.hasPrerequisiteLink = (item.Blocked_By__c != null);
        return view;
    }

    /**
     * The group letter carried in `Task_Group__c` (`B. Earnest Money Wire` -> `B`). Handles
     * `H2` with no special case because it does not cap the letter at one character.
     *
     * @param taskGroup The `Task_Group__c` value.
     * @return Upper-cased letter, or null when it cannot be read.
     */
    public static String letterOf(String taskGroup) {
        if (String.isBlank(taskGroup)) {
            return null;
        }
        String letter = taskGroup.contains('.') ? taskGroup.substringBefore('.') : taskGroup;
        return upper(letter);
    }

    /**
     * @param letter   Group letter.
     * @param sequence Item sequence.
     * @return The display/index coordinate, e.g. `B2`; null when either part is absent.
     */
    public static String coordinateOf(String letter, Integer sequence) {
        if (String.isBlank(letter) || sequence == null) {
            return null;
        }
        return upper(letter) + String.valueOf(sequence);
    }

    /** @param legacyTask A Task. @return The legacy subject parse, copied from TaskRollupService. */
    private static Boolean isLegacyWireTask(Task legacyTask) {
        return legacyTask.Subject != null
            && legacyTask.Subject.toLowerCase().contains('anti-fraud');
    }

    /**
     * @param legacyTask The source Task.
     * @param itemDef    Its definition.
     * @param parent     The pending checklist it belongs under.
     * @param letter     The group letter.
     * @param dealId     The deal, carried rather than traversed — see `PendingItem.dealId`.
     * @return A pending item with `Blocked_By__c` BLANK (rule 4).
     */
    private static PendingItem buildItem(
        Task legacyTask,
        Transaction_Task_Def__mdt itemDef,
        PendingChecklist parent,
        String letter,
        Id dealId
    ) {
        Checklist_Item__c item = new Checklist_Item__c();
        item.Subject__c = itemDef.Subject__c;
        item.Sequence__c = legacyTask.Task_Sequence__c;
        item.Owner_Label__c = String.isNotBlank(legacyTask.Task_Owner_Label__c)
            ? legacyTask.Task_Owner_Label__c
            : (String.isNotBlank(itemDef.Owner_Label__c)
                ? itemDef.Owner_Label__c
                : parent.record.Owner_Label__c);
        item.Is_Conditional__c = (legacyTask.Conditional__c == true);
        item.Is_Critical__c = (itemDef.Is_Critical__c == true);
        item.Is_Wire_Verification__c = (itemDef.Is_Wire_Verification__c == true);
        item.Flag__c = legacyTask.IsClosed
            ? FLAG_FOR_CLOSED_TASK
            : ChecklistItemDomain.openFlagFor(itemDef.Is_Critical__c);
        item.Stage__c = String.isNotBlank(itemDef.Stage_Override__c)
            ? itemDef.Stage_Override__c
            : parent.record.Stage__c;
        item.Due_Date__c = legacyTask.ActivityDate;
        // 🔴 TRUNCATED, NOT COPIED. `Task.Description` is a LongTextArea of 32,000; `Comment__c`
        // is 4,000. ONE live Task over 4,000 characters would throw `STRING_TOO_LONG` on the item
        // insert, and because that statement is `allOrNone = true` it would fail the ENTIRE
        // 25-deal chunk - so a single verbose note on one deal blocks twenty-four innocent ones.
        // ⚠ This is the ONLY unbounded-to-bounded mapping in the projection. Every other text
        // field copied here is Task-side bounded (Subject 255 -> Subject__c 255,
        // Task_Owner_Label__c -> Owner_Label__c, Verified_By__c -> Verified_By_Name__c). If a new
        // mapping is added, check its two lengths before assuming it is safe.
        // ⚠ AND IT IS REPORTED, NOT SILENT: `COMMENT_TRUNCATED` is emitted below as an ADVISORY
        // finding naming the coordinate and both lengths. Advisory rather than blocking on
        // purpose - a long note is not a defect, it is not fixable by whoever runs the migration
        // (shortening it would edit the deal history the migration exists to preserve), and
        // refusing the deal would strand it on the Task model forever. The marker in the text and
        // the line in the report are together what make it not a silent loss.
        item.Comment__c = truncateComment(legacyTask.Description);
        // 🔴 SET EXPLICITLY, AND THAT IS LOAD-BEARING. `ChecklistItemDomain.stampCompletion`
        // runs in before-insert and fills these two ONLY IF NULL. Leaving them null would stamp
        // the MIGRATION RUNNER and NOW onto every historical completion in the org. Supplying
        // them preserves the deal's real history, which the Task model only ever approximated
        // (LastModifiedBy is "who last touched it"); `Is_Prerequisite_Met__c` is deliberately
        // NOT set here — the trigger recomputes it on the link pass.
        item.Completed_By__c = legacyTask.IsClosed ? legacyTask.LastModifiedById : null;
        item.Completed_DateTime__c = legacyTask.IsClosed ? legacyTask.LastModifiedDate : null;
        item.Verbal_Verification_Completed__c = (legacyTask.Verbal_Verification_Completed__c == true);
        item.Verified_By_Name__c = legacyTask.Verified_By__c;
        item.Verification_Phone__c = legacyTask.Verification_Phone__c;
        item.Verified_DateTime__c = legacyTask.Verified_At__c;

        PendingItem pending = new PendingItem();
        pending.record = item;
        pending.dealId = dealId;
        pending.letter = letter;
        pending.sequence = Integer.valueOf(legacyTask.Task_Sequence__c);
        if (itemDef.Blocked_By_Sequence__c != null) {
            pending.blockedByLetter = String.isNotBlank(itemDef.Blocked_By_Group_Letter__c)
                ? upper(itemDef.Blocked_By_Group_Letter__c)
                : letter;
            pending.blockedBySequence = Integer.valueOf(itemDef.Blocked_By_Sequence__c);
        }
        return pending;
    }

    /**
     * A pending item's view. `hasPrerequisiteLink` reports what the SERVICE WILL WRITE in its
     * second pass, not what the unsaved record carries — the record carries nothing by rule 4,
     * and reporting that would make `PREREQ_UNRESOLVED` fire on every gated item of every deal.
     *
     * @param pending The pending item.
     * @return Its view.
     */
    private static ItemView viewOfPending(PendingItem pending) {
        ItemView view = new ItemView();
        view.letter = pending.letter;
        view.sequence = pending.sequence;
        view.done = ChecklistItemDomain.isDone(pending.record.Flag__c);
        view.critical = (pending.record.Is_Critical__c == true);
        view.wireVerification = (pending.record.Is_Wire_Verification__c == true);
        view.verbal = (pending.record.Verbal_Verification_Completed__c == true);
        view.dueDate = pending.record.Due_Date__c;
        view.hasPrerequisiteLink = (pending.blockedBySequence != null);
        return view;
    }

    /**
     * @param findings     Accumulator.
     * @param taskCounters Legacy side.
     * @param itemCounters Checklist side.
     */
    private static void addCounterFindings(
        List<Discrepancy> findings,
        Counters taskCounters,
        Counters itemCounters
    ) {
        addCounter(findings, 'Tasks_Total__c', taskCounters.total, itemCounters.total);
        addCounter(findings, 'Tasks_Complete__c', taskCounters.complete, itemCounters.complete);
        addCounter(findings, 'Tasks_Overdue__c', taskCounters.overdue, itemCounters.overdue);
        addCounter(findings, 'Wire_Open_Risks__c', taskCounters.wireOpen, itemCounters.wireOpen);
    }

    /**
     * @param findings Accumulator.
     * @param name     Counter field name.
     * @param fromTask Legacy value.
     * @param fromItem Checklist value.
     */
    private static void addCounter(
        List<Discrepancy> findings,
        String name,
        Integer fromTask,
        Integer fromItem
    ) {
        if (fromTask != fromItem) {
            findings.add(new Discrepancy(Severity.BLOCKING, 'COUNTER_MISMATCH', name,
                String.valueOf(fromTask), String.valueOf(fromItem)));
        }
    }

    /**
     * The STORED `Transaction__c` counters against the Task-derived ones. ADVISORY ONLY and it
     * must stay that way: the seed scripts ASSIGN `Tasks_Complete__c` directly
     * (`scripts/seed-transactions.apex`, `seed-transactions-nondestructive.apex`), so a
     * disagreement here is pre-existing Task-model drift, not a migration defect. Gating on it
     * would refuse deals for something the migration neither caused nor can fix.
     *
     * @param findings       Accumulator.
     * @param storedCounters The Transaction's stored values, projected at the call site.
     * @param taskCounters   Recomputed from the Tasks.
     */
    private static void addStoredDriftFindings(
        List<Discrepancy> findings,
        Counters storedCounters,
        Counters taskCounters
    ) {
        if (storedCounters == null) {
            return;
        }
        addDrift(findings, 'Tasks_Total__c', storedCounters.total, taskCounters.total);
        addDrift(findings, 'Tasks_Complete__c', storedCounters.complete, taskCounters.complete);
        addDrift(findings, 'Tasks_Overdue__c', storedCounters.overdue, taskCounters.overdue);
        addDrift(findings, 'Wire_Open_Risks__c', storedCounters.wireOpen, taskCounters.wireOpen);
    }

    /**
     * @param findings Accumulator.
     * @param name     Counter field name.
     * @param stored   Value on the Transaction; null is skipped, never reported as 0.
     * @param derived  Value recomputed from the Tasks.
     */
    private static void addDrift(
        List<Discrepancy> findings,
        String name,
        Integer stored,
        Integer derived
    ) {
        if (stored == null || stored == derived) {
            return;
        }
        findings.add(new Discrepancy(Severity.ADVISORY, 'STORED_COUNTER_DRIFT', name,
            String.valueOf(derived), 'stored=' + String.valueOf(stored)));
    }

    /**
     * @param projection Accumulator.
     * @param impact     Severity.
     * @param checkName  Check name.
     * @param coordinate Coordinate or null.
     * @param taskValue  Legacy value.
     * @param itemValue  Checklist value.
     */
    private static void add(Projection projection, Severity impact, String checkName,
            String coordinate, String taskValue, String itemValue) {
        projection.discrepancies.add(
            new Discrepancy(impact, checkName, coordinate, taskValue, itemValue));
        if (impact == Severity.BLOCKING) {
            projection.isReconciled = false;
        }
    }

    /**
     * @param groupDefs Group definitions.
     * @return Indexed by upper-cased `Letter__c`.
     */
    private static Map<String, Task_Group_Def__mdt> indexGroups(List<Task_Group_Def__mdt> groupDefs) {
        Map<String, Task_Group_Def__mdt> byLetter = new Map<String, Task_Group_Def__mdt>();
        if (groupDefs == null) {
            return byLetter;
        }
        for (Task_Group_Def__mdt groupDef : groupDefs) {
            if (String.isNotBlank(groupDef.Letter__c)) {
                byLetter.put(upper(groupDef.Letter__c), groupDef);
            }
        }
        return byLetter;
    }

    /**
     * @param itemDefs Item definitions.
     * @return Indexed by coordinate.
     */
    private static Map<String, Transaction_Task_Def__mdt> indexDefs(
        List<Transaction_Task_Def__mdt> itemDefs
    ) {
        Map<String, Transaction_Task_Def__mdt> byCoordinate =
            new Map<String, Transaction_Task_Def__mdt>();
        if (itemDefs == null) {
            return byCoordinate;
        }
        for (Transaction_Task_Def__mdt itemDef : itemDefs) {
            if (String.isBlank(itemDef.Group_Letter__c) || itemDef.Sequence__c == null) {
                continue;
            }
            byCoordinate.put(
                coordinateOf(itemDef.Group_Letter__c, Integer.valueOf(itemDef.Sequence__c)),
                itemDef);
        }
        return byCoordinate;
    }

    /**
     * Deterministic key order so two runs of the report can be diffed line for line. Apex Map
     * key order is not guaranteed, and a report whose lines move between runs is unusable.
     *
     * ⚠ Takes a `Set<String>`, not a map: Apex generics are INVARIANT, so a
     * `Map<String, Task>` will not bind to a `Map<String, Object>` parameter and the
     * obvious-looking signature does not compile.
     *
     * @param source Any string key set.
     * @return Its members, sorted.
     */
    private static List<String> sortedKeys(Set<String> source) {
        List<String> keys = new List<String>(source);
        keys.sort();
        return keys;
    }

    /** @param value Any string. @return Trimmed and upper-cased, or null. */
    private static String upper(String value) {
        return String.isBlank(value) ? null : value.trim().toUpperCase();
    }
}
