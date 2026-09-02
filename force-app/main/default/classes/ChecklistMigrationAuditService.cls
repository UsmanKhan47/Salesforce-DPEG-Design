/**
 * Phase 4 M2 — the reconciliation report that GATES CUTOVER. Per deal, per check, per coordinate:
 * does the `Checklist_Item__c` model agree with the `Task` model it replaced?
 *
 * layer=service. Read-only: zero DML, and every SOQL delegated to `TransactionSelector` /
 * `TaskSelector` / `ChecklistItemSelector`. Driven from
 * `scripts/reconcile-checklist-migration.apex`.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 A DISAGREEMENT IS LOUD AND SPECIFIC. THERE ARE NO PERCENTAGES ANYWHERE IN THIS CLASS.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Every finding names the deal, the check and — where the check is per-item — the COORDINATE
 * (`B2`, `F12`, `H2:5`). The trailer counts DEALS. "97% agreement" is unactionable and hides
 * which 3%, and the one number anybody needs is the last line: `CUTOVER: CLEAR` or
 * `CUTOVER: BLOCKED`. Greppable, deterministic, and it is the artefact M3 waits on.
 *
 * ⚠ THE COMPARISON ITSELF IS NOT HERE. It is `ChecklistMigrationDomain.compare`, the SAME method
 * `ChecklistMigrationService` runs as its pre-DML gate. Two mechanisms sharing one predicate
 * cannot drift; two implementations of "do these agree?" would, and the drift would show up as a
 * green report over a migration that was refusing deals for a reason the report cannot see.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * TWO MODES, AND BOTH ARE NEEDED. THE MODE IS PRINTED ON EVERY LINE'S DEAL HEADER.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 *   PERSISTED — the deal IS migrated. Compared against the rows actually in the database, which
 *               proves the DML landed what the projection promised. This is the mode that gates
 *               cutover.
 *   PROJECTED — the deal is NOT migrated. Compared against a fresh projection, which explains
 *               exactly WHY `ChecklistMigrationService` refused it. Without this mode a refused
 *               deal is just a flag that did not flip.
 *
 * ⚠ CAPPED AT `MAX_DEALS_PER_RUN` = 25, AND THE LIMIT IS HEAP, NOT SOQL. This holds both models
 * in memory simultaneously (25 x (82 Tasks + 82 items + 11 checklists) is roughly 4,400
 * sObjects), and a synchronous run has a 6 MB ceiling where the migration's async one has 12 MB.
 * Exceeding the cap THROWS rather than silently truncating: a reconciliation that quietly
 * reported on fewer deals than it was asked about is worse than no reconciliation, because the
 * missing deals would read as absent-therefore-clean.
 *
 * @see force-app/main/default/classes/ChecklistMigrationDomain.cls
 * @see force-app/main/default/classes/ChecklistMigrationService.cls
 * @see agent-output/phase4-migration-design.md §3
 */
public with sharing class ChecklistMigrationAuditService {

    /** See the header: a heap bound, deliberately enforced by a throw rather than a truncate. */
    @TestVisible
    private static final Integer MAX_DEALS_PER_RUN = 25;

    /** Extra `Transaction__c` fields the advisory stored-counter drift check needs. */
    @TestVisible
    private static final Set<String> STORED_COUNTER_FIELDS = new Set<String>{
        'Tasks_Total__c', 'Tasks_Complete__c', 'Tasks_Overdue__c', 'Wire_Open_Risks__c'
    };

    /**
     * Test injection point for `Task_Group_Def__mdt`.
     *
     * 🔴 THIS SEAM EXISTS BECAUSE ITS ABSENCE WAS A REAL DEFECT, NOT FOR SYMMETRY. Until it was
     * added, this class called the two providers directly while `ChecklistMigrationService` used
     * its own overrides - so a test that migrated with a FIXTURE definition set then reconciled
     * against the org LIVE CMDT. Those tests passed only because the loader happened to have been
     * run; on an org where it has not, `defByCoordinate` is empty, every coordinate reports
     * NO_DEFINITION, and the CLEAN tests go red for a reason that has nothing to do with the code
     * under test. A fixture comment in the test class claimed the overrides reached BOTH consumers.
     * They did not.
     * ⚠ A TEST THAT SETS THE SERVICE OVERRIDES MUST SET THESE TOO. They are deliberately separate
     * fields rather than a shared holder: the two classes are independently deployable and one
     * borrowing the other test seam would be a hidden compile-time coupling.
     */
    @TestVisible
    static List<Task_Group_Def__mdt> groupDefsOverride;

    /** Test injection point for `Transaction_Task_Def__mdt`. See `groupDefsOverride`. */
    @TestVisible
    static List<Transaction_Task_Def__mdt> taskDefsOverride;

    /** @return The group definitions, honouring the test override. */
    private static List<Task_Group_Def__mdt> groupDefs() {
        return groupDefsOverride != null
            ? groupDefsOverride
            : TaskGroupDefProvider.getAllOrderedBySequence();
    }

    /** @return The item definitions, honouring the test override. */
    private static List<Transaction_Task_Def__mdt> itemDefs() {
        return taskDefsOverride != null
            ? taskDefsOverride
            : TransactionTaskDefProvider.getAllOrderedByGroupAndSequence();
    }

    /** Raised when a caller asks for more deals than one synchronous run can hold. */
    public class AuditScopeException extends Exception {}

    /** One deal's verdict. */
    public class DealVerdict {
        /** The deal. */
        public Id transactionId;
        /** `PERSISTED` or `PROJECTED`. */
        public String mode;
        /** Every finding, blocking and advisory, in check order. */
        public List<ChecklistMigrationDomain.Discrepancy> discrepancies =
            new List<ChecklistMigrationDomain.Discrepancy>();

        /** @return true when nothing BLOCKING was found. Advisory findings do not block. */
        public Boolean isClean() {
            for (ChecklistMigrationDomain.Discrepancy finding : discrepancies) {
                if (finding.impact == ChecklistMigrationDomain.Severity.BLOCKING) {
                    return false;
                }
            }
            return true;
        }
    }

    /**
     * Reconciles the supplied deals.
     *
     * @param transactionIds Deals to reconcile. Null/empty-safe.
     * @return One verdict per deal asked for, in the order asked.
     * @throws AuditScopeException when more than `MAX_DEALS_PER_RUN` deals are supplied.
     * @example
     * List<ChecklistMigrationAuditService.DealVerdict> verdicts =
     *     ChecklistMigrationAuditService.compare(dealIds);
     */
    public static List<DealVerdict> compare(List<Id> transactionIds) {
        List<DealVerdict> verdicts = new List<DealVerdict>();
        if (transactionIds == null || transactionIds.isEmpty()) {
            return verdicts;
        }
        if (transactionIds.size() > MAX_DEALS_PER_RUN) {
            throw new AuditScopeException(
                'Reconcile at most ' + MAX_DEALS_PER_RUN + ' deals per run (asked for '
                + transactionIds.size() + '). This is a HEAP bound, not a SOQL one - the report '
                + 'holds both models in memory at once. Chunk the list and run it again; the '
                + 'report is per deal, so the chunks concatenate cleanly.');
        }

        Set<Id> dealIds = new Set<Id>(transactionIds);
        dealIds.remove(null);
        if (dealIds.isEmpty()) {
            return verdicts;
        }

        Map<Id, Transaction__c> deals =
            TransactionSelector.selectForChecklistFanout(dealIds, STORED_COUNTER_FIELDS);
        Map<Id, List<Task>> tasksByDeal = groupTasksByDeal(
            TaskSelector.selectForChecklistMigration(dealIds));
        Map<Id, List<Checklist_Item__c>> itemsByDeal = groupItemsByDeal(
            ChecklistItemSelector.selectByTransactionIds(dealIds));

        List<Task_Group_Def__mdt> groupDefs = groupDefs();
        List<Transaction_Task_Def__mdt> itemDefs = itemDefs();
        Map<String, Transaction_Task_Def__mdt> defByCoordinate = indexDefs(itemDefs);
        Date today = Date.today();

        for (Id dealId : transactionIds) {
            if (dealId == null) {
                continue;
            }
            DealVerdict verdict = new DealVerdict();
            verdict.transactionId = dealId;
            verdicts.add(verdict);

            Transaction__c deal = deals.get(dealId);
            if (deal == null) {
                verdict.mode = 'PROJECTED';
                verdict.discrepancies.add(new ChecklistMigrationDomain.Discrepancy(
                    ChecklistMigrationDomain.Severity.BLOCKING, 'NOT_VISIBLE', null,
                    'requested', 'no row returned - check DPEG_Transactions_Team membership'));
                continue;
            }

            List<Task> tasks = tasksByDeal.get(dealId);
            if (deal.Checklist_Fanned_Out__c != true) {
                // PROJECTED: re-run the migration's own gate, read-only, to say why it refused.
                verdict.mode = 'PROJECTED';
                verdict.discrepancies = ChecklistMigrationDomain.project(
                    dealId, storedCountersOf(deal), tasks, groupDefs, itemDefs, today
                ).discrepancies;
                continue;
            }

            // PERSISTED: the rows actually in the database, which is what gates cutover.
            verdict.mode = 'PERSISTED';
            List<ChecklistMigrationDomain.ItemView> views =
                new List<ChecklistMigrationDomain.ItemView>();
            List<Checklist_Item__c> items = itemsByDeal.get(dealId);
            if (items != null) {
                for (Checklist_Item__c item : items) {
                    views.add(ChecklistMigrationDomain.viewOf(item));
                }
            }
            verdict.discrepancies = ChecklistMigrationDomain.compare(
                ChecklistMigrationDomain.fromTasks(tasks, today),
                ChecklistMigrationDomain.countItems(views, today),
                views,
                indexTasks(tasks),
                defByCoordinate,
                storedCountersOf(deal));
        }
        return verdicts;
    }

    /**
     * Renders the verdicts as the operator-facing report. Deterministic: the deal order is the
     * order asked for, and `ChecklistMigrationDomain` sorts every per-coordinate finding, so two
     * runs over the same data diff to nothing.
     *
     * ⚠ ASCII ONLY. `addError` HTML-escapes, and this text is also read out of an Apex debug log
     * where non-ASCII renders unpredictably. No box-drawing, no arrows, no smart quotes.
     *
     * @param verdicts The verdicts to render.
     * @return The full report, ending in `CUTOVER: CLEAR` or `CUTOVER: BLOCKED`.
     * @example
     * System.debug(ChecklistMigrationAuditService.format(verdicts));
     */
    public static String format(List<DealVerdict> verdicts) {
        List<String> lines = new List<String>();
        lines.add('== CHECKLIST MIGRATION RECONCILIATION ==');
        if (verdicts == null || verdicts.isEmpty()) {
            lines.add('No deals supplied. NOTHING WAS CHECKED - this is not a pass.');
            lines.add('CUTOVER: BLOCKED');
            return String.join(lines, '\n');
        }
        lines.add('deals asked : ' + verdicts.size());
        lines.add('--------------------------------------------------------------------------');

        Integer clean = 0;
        Integer discrepant = 0;
        Integer notVisible = 0;
        for (DealVerdict verdict : verdicts) {
            Boolean isClean = verdict.isClean();
            if (isClean) {
                clean++;
            } else {
                discrepant++;
            }
            lines.add(String.valueOf(verdict.transactionId) + '  [' + verdict.mode + ']  '
                + (isClean ? 'CLEAN' : 'DISCREPANT'));
            for (ChecklistMigrationDomain.Discrepancy finding : verdict.discrepancies) {
                if (finding.checkName == 'NOT_VISIBLE') {
                    notVisible++;
                }
                lines.add('  [' + String.valueOf(finding.impact) + '] ' + finding.checkName
                    + (String.isBlank(finding.coordinate) ? '' : ' ' + finding.coordinate)
                    + '  tasks=' + finding.taskValue
                    + '  items=' + finding.itemValue);
            }
        }
        lines.add('--------------------------------------------------------------------------');
        lines.add('DEALS COMPARED ' + verdicts.size() + ' | CLEAN ' + clean
            + ' | DISCREPANT ' + discrepant + ' | NOT VISIBLE ' + notVisible);
        lines.add(discrepant == 0
            ? 'CUTOVER: CLEAR'
            : 'CUTOVER: BLOCKED  (' + discrepant + ' deal(s) have blocking discrepancies)');
        return String.join(lines, '\n');
    }

    /**
     * @param tasks Checklist Tasks across several deals.
     * @return Grouped by `Transaction_Deal__c`; never null.
     */
    private static Map<Id, List<Task>> groupTasksByDeal(List<Task> tasks) {
        Map<Id, List<Task>> byDeal = new Map<Id, List<Task>>();
        for (Task legacyTask : tasks) {
            if (legacyTask.Transaction_Deal__c == null) {
                continue;
            }
            List<Task> forDeal = byDeal.get(legacyTask.Transaction_Deal__c);
            if (forDeal == null) {
                forDeal = new List<Task>();
                byDeal.put(legacyTask.Transaction_Deal__c, forDeal);
            }
            forDeal.add(legacyTask);
        }
        return byDeal;
    }

    /**
     * @param items Persisted checklist items across several deals.
     * @return Grouped by `Checklist__r.Transaction__c`; never null.
     */
    private static Map<Id, List<Checklist_Item__c>> groupItemsByDeal(List<Checklist_Item__c> items) {
        Map<Id, List<Checklist_Item__c>> byDeal = new Map<Id, List<Checklist_Item__c>>();
        for (Checklist_Item__c item : items) {
            if (item.Checklist__r == null || item.Checklist__r.Transaction__c == null) {
                continue;
            }
            List<Checklist_Item__c> forDeal = byDeal.get(item.Checklist__r.Transaction__c);
            if (forDeal == null) {
                forDeal = new List<Checklist_Item__c>();
                byDeal.put(item.Checklist__r.Transaction__c, forDeal);
            }
            forDeal.add(item);
        }
        return byDeal;
    }

    /**
     * @param tasks One deal's checklist Tasks; may be null.
     * @return Indexed by coordinate. A duplicate coordinate is dropped here and reported by
     *         `ChecklistMigrationDomain.compare` as a missing item, which is the same finding
     *         from the other side.
     */
    private static Map<String, Task> indexTasks(List<Task> tasks) {
        Map<String, Task> byCoordinate = new Map<String, Task>();
        if (tasks == null) {
            return byCoordinate;
        }
        for (Task legacyTask : tasks) {
            String letter = ChecklistMigrationDomain.letterOf(legacyTask.Task_Group__c);
            if (String.isBlank(letter) || legacyTask.Task_Sequence__c == null) {
                continue;
            }
            byCoordinate.put(
                ChecklistMigrationDomain.coordinateOf(
                    letter, Integer.valueOf(legacyTask.Task_Sequence__c)),
                legacyTask);
        }
        return byCoordinate;
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
        for (Transaction_Task_Def__mdt itemDef : itemDefs) {
            if (String.isBlank(itemDef.Group_Letter__c) || itemDef.Sequence__c == null) {
                continue;
            }
            byCoordinate.put(
                ChecklistMigrationDomain.coordinateOf(
                    itemDef.Group_Letter__c, Integer.valueOf(itemDef.Sequence__c)),
                itemDef);
        }
        return byCoordinate;
    }

    /**
     * @param deal A Transaction loaded WITH `STORED_COUNTER_FIELDS`.
     * @return Its stored counters, for the advisory drift check.
     */
    private static ChecklistMigrationDomain.Counters storedCountersOf(Transaction__c deal) {
        ChecklistMigrationDomain.Counters stored = new ChecklistMigrationDomain.Counters();
        stored.total = intOf(deal.Tasks_Total__c);
        stored.complete = intOf(deal.Tasks_Complete__c);
        stored.overdue = intOf(deal.Tasks_Overdue__c);
        stored.wireOpen = intOf(deal.Wire_Open_Risks__c);
        return stored;
    }

    /** @param value A stored counter. @return Its Integer value, or null when unset. */
    private static Integer intOf(Decimal value) {
        return value == null ? null : value.intValue();
    }
}
