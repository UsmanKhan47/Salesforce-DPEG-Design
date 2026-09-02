/**
 * Pins `ChecklistMigrationDomain` — the projection and the reconciliation that gate Phase 4 M1.
 *
 * 🔴 NO DML AND NO SOQL IN THIS CLASS, MATCHING THE CLASS UNDER TEST. Every fixture is built in
 * memory, including the two Custom Metadata types (CMDT rows cannot be inserted, but the sObjects
 * can be constructed). That is what lets these tests assert the mapping and every discrepancy
 * branch without a Transaction, a Task or a governor budget.
 *
 * ⚠ THE FIXTURES DELIBERATELY USE REAL RESTRICTED-PICKLIST VALUES — `A. Contract Execution &
 * Title Opening`, `Open Contract` — even though nothing is saved here. A fixture that drifts from
 * the org's value set produces a test that passes in memory and a service that throws on DML, and
 * this repo has paid for that shape before.
 *
 * @see force-app/main/default/classes/ChecklistMigrationDomain.cls
 */
@isTest
private class ChecklistMigrationDomainTest {

    private static final Id DEAL_ID = fakeId(Transaction__c.SObjectType, 1);
    private static final String GROUP_A = 'A. Contract Execution & Title Opening';
    private static final String GROUP_B = 'B. Earnest Money Wire';
    private static final String GROUP_H2 = 'H2. Tenant Interviews & Estoppels';

    /**
     * The A1 fixture subject. Carries the legacy (anti-fraud) marker because A1 is the
     * wire-verification definition in defsForA - see that method for why both are required.
     */
    private static final String A1_WIRE_SUBJECT =
        'Call title company to verbally verify wiring instructions (anti-fraud)';

    @isTest
    static void shouldProjectOneItemPerTask_WhenEveryCoordinateHasADefinition() {
        List<Task> tasks = new List<Task>{
            legacyTask(GROUP_A, 1, false, false),
            legacyTask(GROUP_A, 2, true, false)
        };

        ChecklistMigrationDomain.Projection projection = project(tasks, defsForA(), null);

        Assert.isTrue(projection.isReconciled, findings(projection));
        Assert.areEqual(1, projection.checklists.size(), 'One group letter means one checklist.');
        Assert.areEqual(2, projection.itemCount, 'One item per Task, never per definition.');
        Assert.areEqual(2, projection.checklists[0].record.Items_Total__c,
            'Items_Total__c is the count BUILT, not the count DEFINED.');
        Assert.areEqual(1, projection.checklists[0].record.Items_Complete__c,
            'One of the two Tasks was closed.');
    }

    @isTest
    static void shouldCarryCompletionHistory_WhenTaskIsClosed() {
        Task closed = legacyTask(GROUP_A, 2, true, false);
        closed.Description = 'note text';

        ChecklistMigrationDomain.Projection projection =
            project(new List<Task>{ closed }, defsForA(), null);
        Checklist_Item__c item = projection.checklists[0].items[0].record;

        Assert.areEqual(ChecklistItemDomain.FLAG_COMPLETED, item.Flag__c,
            'A closed Task migrates as Completed.');
        Assert.areEqual('note text', item.Comment__c, 'Description carries over to Comment__c.');
        Assert.areEqual(closed.LastModifiedById, item.Completed_By__c,
            'Completed_By__c MUST be set explicitly. ChecklistItemDomain.stampCompletion fills it '
            + 'only IF NULL, so leaving it null would stamp the MIGRATION RUNNER onto every '
            + 'historical completion in the org.');
        Assert.areEqual(closed.LastModifiedDate, item.Completed_DateTime__c,
            'Same reasoning as Completed_By__c: supplying it preserves the real history.');
    }

    @isTest
    static void shouldLeaveCompletionBlank_WhenTaskIsOpen() {
        ChecklistMigrationDomain.Projection projection =
            project(new List<Task>{ legacyTask(GROUP_A, 1, false, false) }, defsForA(), null);
        Checklist_Item__c item = projection.checklists[0].items[0].record;

        Assert.isNull(item.Completed_By__c, 'An open item has no completer.');
        Assert.isNull(item.Completed_DateTime__c, 'An open item has no completion time.');
    }

    @isTest
    static void shouldNeverSetBlockedBy_WhenProjecting() {
        ChecklistMigrationDomain.Projection projection =
            project(wireTasks(), defsForWirePair(), null);

        for (ChecklistMigrationDomain.PendingChecklist pending : projection.checklists) {
            for (ChecklistMigrationDomain.PendingItem item : pending.items) {
                Assert.isNull(item.record.Blocked_By__c,
                    'Blocked_By__c must be BLANK on every projected item. Inserting an '
                    + 'already-complete item that carries a link is refused by the ISNEW() arm of '
                    + 'Prerequisite_Must_Be_Met_To_Complete, and under allOrNone=false that '
                    + 'SILENTLY DROPS exactly the B3/I8 rows.');
            }
        }
    }

    @isTest
    static void shouldCarryPrerequisiteCoordinate_WhenDefinitionDeclaresOne() {
        ChecklistMigrationDomain.Projection projection =
            project(wireTasks(), defsForWirePair(), null);
        ChecklistMigrationDomain.PendingItem dependent = itemAt(projection, 'B', 3);

        Assert.areEqual('B', dependent.blockedByLetter,
            'A blank Blocked_By_Group_Letter__c means the same group as the dependent.');
        Assert.areEqual(2, dependent.blockedBySequence,
            'The prerequisite coordinate travels as data for the service second pass.');
    }

    @isTest
    static void shouldFlagWireVerification_FromDefinitionNotFromSubject() {
        ChecklistMigrationDomain.Projection projection =
            project(wireTasks(), defsForWirePair(), null);

        Assert.isTrue(itemAt(projection, 'B', 2).record.Is_Wire_Verification__c,
            'Is_Wire_Verification__c comes from the CMDT row, not from a subject parse.');
        Assert.isFalse(itemAt(projection, 'B', 3).record.Is_Wire_Verification__c,
            'A non-wire item must not inherit the flag from its group.');
    }

    /**
     * The RISK 1 canary. The definitions say B2 is a wire item; the Task's subject has lost the
     * `anti-fraud` marker. The projection trusts the definition, so the two models disagree — and
     * the reconciliation must REFUSE the deal rather than let the disagreement through.
     */
    @isTest
    static void shouldRefuseDeal_WhenLegacyWireParseDisagreesWithTheDefinition() {
        List<Task> tasks = wireTasks();
        tasks[0].Subject = 'Call title company to verbally verify wiring instructions';

        ChecklistMigrationDomain.Projection projection = project(tasks, defsForWirePair(), null);

        Assert.isFalse(projection.isReconciled,
            'A wire-flag disagreement must refuse the deal - this is the exact silent-to-zero '
            + 'failure the whole rewrite exists to eliminate.');
        Assert.isTrue(hasFinding(projection, 'WIRE_FLAG_MISMATCH', 'B2'),
            'The finding must NAME the coordinate: ' + findings(projection));
    }

    @isTest
    static void shouldRefuseDeal_WhenACoordinateHasNoDefinition() {
        List<Task> tasks = new List<Task>{ legacyTask(GROUP_A, 9, false, false) };

        ChecklistMigrationDomain.Projection projection = project(tasks, defsForA(), null);

        Assert.isFalse(projection.isReconciled,
            'A Task with no definition would build an item with Is_Wire_Verification__c false - '
            + 'i.e. a wire item silently losing its flag. Refuse, do not default.');
        Assert.isTrue(hasFinding(projection, 'NO_DEFINITION', 'A9'), findings(projection));
    }

    @isTest
    static void shouldRefuseDeal_WhenAGroupLetterHasNoGroupDefinition() {
        // 🔴 THE A1 TASK IS NOT DECORATION - IT KEEPS THE FIXTURE INTERNALLY CONSISTENT.
        // A1 is the wire-verification definition in `defsForA`, so a fixture WITHOUT it has no
        // wire item at all, and `compare` then adds a BLOCKING WIRE_ITEM_COUNT on top of the one
        // finding this test is about. That is what happened on 2026-09-02: the earlier fix made A1
        // the wire definition but left this fixture carrying only a B task, so removing the B
        // GROUP cascaded into COORDINATE_MISSING_ITEM, two COUNTER_MISMATCHes and WIRE_ITEM_COUNT
        // - five findings where the assertion expects one. THE RULE: the wire task and its
        // definition travel together, in whichever group survives the scenario under test.
        // ⚠ AND THE B TASK IS AT SEQUENCE 3, NOT 2. `legacyTask(..., wireGroup = true)` gives
        // sequence 2 the `(anti-fraud)` subject, which would make the legacy parse see a SECOND
        // wire row that no definition backs - a real WIRE_FLAG_MISMATCH, and noise this test is
        // not about.
        // ⚠ THE WIRE_ITEM_COUNT TEXT SAYS "run the CMDT loader". THAT IS A RED HERRING HERE:
        // `ChecklistMigrationDomain` is a pure projection with the definitions passed IN, so no
        // `Transaction_Task_Def__mdt` row can change this outcome. Fix the fixture, not the org.
        List<Task> tasks = new List<Task>{
            legacyTask(GROUP_A, 1, false, false),
            legacyTask(GROUP_B, 3, false, true)
        };

        // 🔴 THE GROUP DEFS ARE WITHHELD FOR B, WHICH IS WHAT THE METHOD NAME DESCRIBES.
        // Until 2026-09-02 this passed the DEFAULT group defs (A and B) and withheld only the
        // ITEM defs, so `NO_GROUP_DEFINITION` could never fire - `groupByLetter.get(letter)` was
        // never null - and the domain correctly reported coordinate-level `NO_DEFINITION B3`
        // instead. The domain was right; the fixture built a different scenario from the one the
        // name and the assertion describe. See the `project` overload for why the assertion was
        // NOT retargeted at `NO_DEFINITION` instead.
        ChecklistMigrationDomain.Projection projection =
            project(tasks, groupDefsWithoutB(), defsForA(), null);

        Assert.isFalse(projection.isReconciled,
            'Without a group definition the checklist carries no Stage__c and its phase tab '
            + 'renders empty.');
        Assert.isTrue(hasFinding(projection, 'NO_GROUP_DEFINITION', 'B'), findings(projection));
    }

    @isTest
    static void shouldRefuseDeal_WhenTwoTasksShareACoordinate() {
        List<Task> tasks = new List<Task>{
            legacyTask(GROUP_A, 1, false, false),
            legacyTask(GROUP_A, 1, true, false)
        };

        ChecklistMigrationDomain.Projection projection = project(tasks, defsForA(), null);

        Assert.isFalse(projection.isReconciled, 'An ambiguous coordinate cannot be migrated.');
        Assert.isTrue(hasFinding(projection, 'COORDINATE_DUPLICATE', 'A1'), findings(projection));
    }

    @isTest
    static void shouldRefuseDeal_WhenItHasNoChecklistTasks() {
        ChecklistMigrationDomain.Projection projection =
            project(new List<Task>(), defsForA(), null);

        Assert.isFalse(projection.isReconciled, 'There is nothing to migrate.');
        Assert.isTrue(hasFinding(projection, 'NO_CHECKLIST_TASKS', ''), findings(projection));
    }

    /**
     * The DEFINITION_WITHOUT_TASK judgement call. Rule 2 says the migration is faithful to the
     * Tasks that EXIST, so a deleted Task is a fact about the deal. It must be NAMED but must not
     * refuse the deal — otherwise every deal anyone ever tidied becomes un-migratable.
     */
    @isTest
    static void shouldReportButNotRefuse_WhenADefinitionHasNoTask() {
        List<Task> tasks = new List<Task>{ legacyTask(GROUP_A, 1, false, false) };

        ChecklistMigrationDomain.Projection projection = project(tasks, defsForA(), null);

        Assert.isTrue(projection.isReconciled,
            'A missing Task is ADVISORY. Making it blocking would refuse every deal anyone has '
            + 'ever tidied: ' + findings(projection));
        Assert.isTrue(hasFinding(projection, 'DEFINITION_WITHOUT_TASK', 'A2'),
            'It must still be named, per coordinate: ' + findings(projection));
    }

    /**
     * ⚠ THE CRITICAL COUNT IS DERIVED, NOT 4. Design §7 says "assert the CRITICAL count is 4 per
     * deal", which is wrong for a no-loan deal — F12 lives in conditional group F. Here only one
     * of the two definitions in scope is critical, so the expectation is 1 and a hardcoded 4
     * would red-line a perfectly good deal.
     */
    @isTest
    static void shouldDeriveCriticalCountFromTheGroupsTheDealActuallyHas() {
        List<Task> tasks = wireTasks();

        ChecklistMigrationDomain.Projection projection = project(tasks, defsForWirePair(), null);

        Assert.isTrue(projection.isReconciled,
            'One critical definition in scope means one critical item. A hardcoded 4 would '
            + 'refuse this: ' + findings(projection));
        Assert.isTrue(itemAt(projection, 'B', 2).record.Is_Critical__c,
            'B2 is the critical one in this fixture.');
        Assert.areEqual(ChecklistItemDomain.FLAG_CRITICAL, itemAt(projection, 'B', 2).record.Flag__c,
            'An OPEN critical item opens on CRITICAL, from Is_Critical__c and never a regex.');
    }

    /** `H2` is the one two-character letter and it must need no special case. */
    @isTest
    static void shouldReadTwoCharacterGroupLetter_WhenGroupIsH2() {
        Assert.areEqual('H2', ChecklistMigrationDomain.letterOf(GROUP_H2),
            'The letter is everything before the first dot, not the first character.');
        Assert.areEqual('H25', ChecklistMigrationDomain.coordinateOf('h2', 5),
            'Coordinates are upper-cased so map lookups cannot miss on case.');
        Assert.isNull(ChecklistMigrationDomain.letterOf(null), 'Null in, null out.');
        Assert.isNull(ChecklistMigrationDomain.coordinateOf('A', null),
            'A coordinate with no sequence is not a coordinate.');
    }

    @isTest
    static void shouldRefuseDeal_WhenTransactionIdIsNull() {
        ChecklistMigrationDomain.Projection projection = ChecklistMigrationDomain.project(
            null, null, new List<Task>{ legacyTask(GROUP_A, 1, false, false) },
            groupDefs(), defsForA(), Date.today());

        Assert.isFalse(projection.isReconciled, 'A deal that could not be read cannot be migrated.');
        Assert.isTrue(hasFinding(projection, 'NOT_VISIBLE', ''), findings(projection));
    }

    /** Stored drift is ADVISORY: the seed scripts assign these counters directly. */
    @isTest
    static void shouldReportButNotRefuse_WhenStoredCountersDrift() {
        ChecklistMigrationDomain.Counters stored = new ChecklistMigrationDomain.Counters();
        stored.total = 99;
        stored.complete = 99;
        stored.overdue = 0;
        stored.wireOpen = 0;

        ChecklistMigrationDomain.Projection projection =
            project(wireTasks(), defsForWirePair(), stored);

        Assert.isTrue(projection.isReconciled,
            'Stored drift must never block - it is pre-existing Task-model drift the migration '
            + 'neither caused nor can fix: ' + findings(projection));
        Assert.isTrue(hasFinding(projection, 'STORED_COUNTER_DRIFT', 'Tasks_Total__c'),
            findings(projection));
    }

    @isTest
    static void shouldCountOverdueOnlyForOpenRows() {
        List<Task> tasks = new List<Task>{
            legacyTask(GROUP_A, 1, false, false),
            legacyTask(GROUP_A, 2, true, false)
        };
        tasks[0].ActivityDate = Date.today().addDays(-5);
        tasks[1].ActivityDate = Date.today().addDays(-5);

        ChecklistMigrationDomain.Counters counters =
            ChecklistMigrationDomain.fromTasks(tasks, Date.today());

        Assert.areEqual(1, counters.overdue,
            'TaskRollupService uses an ELSE-IF, so a CLOSED past-due row is complete and not '
            + 'overdue. Copying that exactly is what makes the reconciliation meaningful.');
        Assert.areEqual(1, counters.complete, 'One closed row.');
    }


    /**
     * 🔴 C3. `Task.Description` is 32,000; `Comment__c` is 4,000. Without truncation ONE verbose
     * note on ONE deal throws `STRING_TOO_LONG` on the item insert, and because that statement is
     * `allOrNone = true` it fails the ENTIRE 25-deal chunk - twenty-four innocent deals blocked by
     * somebody having pasted an email into a checklist note.
     */
    @isTest
    static void shouldTruncateComment_WhenDescriptionExceedsTheFieldLength() {
        Task verbose = legacyTask(GROUP_A, 1, false, false);
        verbose.Description = 'x'.repeat(5000);

        ChecklistMigrationDomain.Projection projection =
            project(new List<Task>{ verbose }, defsForA(), null);
        String comment = projection.checklists[0].items[0].record.Comment__c;

        Assert.areEqual(ChecklistMigrationDomain.COMMENT_MAX_LENGTH, comment.length(),
            'The value must fit EXACTLY, marker included. One character over and the insert '
            + 'throws STRING_TOO_LONG and takes the whole chunk with it.');
        Assert.isTrue(comment.endsWith('[truncated by checklist migration]'),
            'And the loss must be VISIBLE in the data, not only in the report.');
    }

    /** The loss must also be named per coordinate - ADVISORY, because it is not fixable. */
    @isTest
    static void shouldReportButNotRefuse_WhenACommentWasTruncated() {
        Task verbose = legacyTask(GROUP_A, 1, false, false);
        verbose.Description = 'x'.repeat(5000);

        ChecklistMigrationDomain.Projection projection =
            project(new List<Task>{ verbose }, defsForA(), null);

        Assert.isTrue(projection.isReconciled,
            'A long note is not a defect and cannot be fixed by the migration runner - shortening '
            + 'it would edit the deal history the migration exists to preserve. Blocking here '
            + 'would strand the deal on the Task model forever: ' + findings(projection));
        Assert.isTrue(hasFinding(projection, 'COMMENT_TRUNCATED', 'A1'), findings(projection));
    }

    /** A description that fits must be carried across byte for byte, with no marker. */
    @isTest
    static void shouldNotTruncateComment_WhenDescriptionFits() {
        Task brief = legacyTask(GROUP_A, 1, false, false);
        brief.Description = 'a short note';

        ChecklistMigrationDomain.Projection projection =
            project(new List<Task>{ brief }, defsForA(), null);

        Assert.areEqual('a short note',
            projection.checklists[0].items[0].record.Comment__c,
            'A value inside the limit must not be marked or altered.');
        Assert.isFalse(hasFinding(projection, 'COMMENT_TRUNCATED', 'A1'),
            'And must not be reported: ' + findings(projection));
    }
    /**
     * Projects with the DEFAULT group definitions (A and B).
     *
     * @param tasks    Legacy Tasks.
     * @param itemDefs Item definitions in scope.
     * @param stored   Stored counters, or null to skip the advisory drift check.
     * @return The projection.
     */
    private static ChecklistMigrationDomain.Projection project(
        List<Task> tasks,
        List<Transaction_Task_Def__mdt> itemDefs,
        ChecklistMigrationDomain.Counters stored
    ) {
        return project(tasks, groupDefs(), itemDefs, stored);
    }

    /**
     * Projects with a CALLER-SUPPLIED group-definition list.
     *
     * 🔴 THIS OVERLOAD EXISTS SO A TEST CAN WITHHOLD A **GROUP** DEFINITION. Without it every
     * caller got `groupDefs()`, which returns rows for BOTH A and B - and
     * `ChecklistMigrationDomain` raises `NO_GROUP_DEFINITION` only when `groupByLetter.get(letter)`
     * is null, so that branch was UNREACHABLE FROM THIS CLASS and had no coverage anywhere.
     * `shouldRefuseDeal_WhenAGroupLetterHasNoGroupDefinition` was withholding `defsForA` - the
     * ITEM defs - which is a different scenario, so the domain correctly reported coordinate-level
     * `NO_DEFINITION` and the test failed against its own name.
     * ⚠ THE OTHER "FIX" WAS TO RETARGET THE ASSERTION AT `NO_DEFINITION`. That was rejected: it
     * would have gone green while leaving `NO_GROUP_DEFINITION` - a BLOCKING check in the gate
     * that decides cutover - with zero coverage, and the method name would still have been a lie.
     * Mirrors `ChecklistMigrationServiceTest`, which does the same thing through
     * `ChecklistMigrationService.groupDefsOverride`.
     *
     * @param tasks        Legacy Tasks.
     * @param groupDefsForRun Group definitions for this run; pass a subset to withhold a letter.
     * @param itemDefs     Item definitions in scope.
     * @param stored       Stored counters, or null to skip the advisory drift check.
     * @return The projection.
     */
    private static ChecklistMigrationDomain.Projection project(
        List<Task> tasks,
        List<Task_Group_Def__mdt> groupDefsForRun,
        List<Transaction_Task_Def__mdt> itemDefs,
        ChecklistMigrationDomain.Counters stored
    ) {
        return ChecklistMigrationDomain.project(
            DEAL_ID, stored, tasks, groupDefsForRun, itemDefs, Date.today());
    }

    /**
     * @return ONLY the group A definition - so a caller can prove `NO_GROUP_DEFINITION` fires for
     *         B while A still projects normally. A truly empty list would make EVERY letter report
     *         it, which is a blunter scenario than the method under test describes.
     */
    private static List<Task_Group_Def__mdt> groupDefsWithoutB() {
        return new List<Task_Group_Def__mdt>{ groupDefs()[0] };
    }

    /** @return Group definitions for A and B, both non-conditional, phase Open Contract. */
    private static List<Task_Group_Def__mdt> groupDefs() {
        return new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'A', Group_Name__c = 'Contract Execution',
                Owner_Label__c = 'Legal', Sequence__c = 1, Stage__c = 'Open Contract',
                Conditional__c = false),
            new Task_Group_Def__mdt(Letter__c = 'B', Group_Name__c = 'Earnest Money Wire',
                Owner_Label__c = 'CFO', Sequence__c = 2, Stage__c = 'Open Contract',
                Conditional__c = false)
        };
    }

    /**
     * @return Two definitions in group A. A2 has no Task in most fixtures, on purpose.
     *
     * 🔴 A1 IS THE WIRE-VERIFICATION DEFINITION, AND IT HAS TO BE. ChecklistMigrationDomain.compare
     * emits a BLOCKING WIRE_ITEM_COUNT when NO definition in scope carries
     * Is_Wire_Verification__c - because a deal with no wire item makes Wire_Open_Risks__c
     * structurally zero on BOTH models, so the
     * agreement is vacuous and the RISK 1 canary proves nothing. Four tests here failed on
     * 2026-09-02 for exactly that reason: the fixture, not the code.
     * ⚠ ITS SUBJECT MUST CARRY THE (anti-fraud) MARKER TOO. The reconciliation compares the
     * legacy SUBJECT PARSE against the boolean field on the same row, so a def flagged as a wire
     * item whose Task subject lacks the marker is a genuine WIRE_FLAG_MISMATCH - which is the
     * canary firing correctly. The two must move together in any fixture.
     */
    private static List<Transaction_Task_Def__mdt> defsForA() {
        return new List<Transaction_Task_Def__mdt>{
            itemDef('A', 1, A1_WIRE_SUBJECT, false, true, null, null),
            itemDef('A', 2, 'Receive critical dates from title company', false, false, null, null)
        };
    }

    /** @return The B2 -> B3 wire pair: B2 critical and wire-verifying, B3 gated behind it. */
    private static List<Transaction_Task_Def__mdt> defsForWirePair() {
        return new List<Transaction_Task_Def__mdt>{
            itemDef('B', 2, 'Call title company to verbally verify wiring instructions (anti-fraud)',
                true, true, null, null),
            itemDef('B', 3, 'Send wire request to accounting with verified instructions',
                false, false, null, 2)
        };
    }

    /** @return A B2 (wire, open) and a B3 (gated, open), both with matching subjects. */
    private static List<Task> wireTasks() {
        return new List<Task>{
            legacyTask(GROUP_B, 2,
                false, true).clone(false, true, false, false),
            legacyTask(GROUP_B, 3, false, true)
        };
    }

    /**
     * @param letter    Group letter.
     * @param sequence  Sequence.
     * @param subject   Subject text.
     * @param critical  Is_Critical__c.
     * @param wire      Is_Wire_Verification__c.
     * @param blockedByLetter   Prerequisite group letter, or null.
     * @param blockedBySequence Prerequisite sequence, or null.
     * @return An in-memory definition row.
     */
    private static Transaction_Task_Def__mdt itemDef(String letter, Integer sequence,
            String subject, Boolean critical, Boolean wire,
            String blockedByLetter, Integer blockedBySequence) {
        return new Transaction_Task_Def__mdt(
            Group_Letter__c = letter,
            Sequence__c = sequence,
            Subject__c = subject,
            Owner_Label__c = 'Legal',
            Is_Critical__c = critical,
            Is_Wire_Verification__c = wire,
            Blocked_By_Group_Letter__c = blockedByLetter,
            Blocked_By_Sequence__c = blockedBySequence
        );
    }

    /**
     * @param taskGroup  Task_Group__c value.
     * @param sequence   Task_Sequence__c.
     * @param closed     Whether it is closed.
     * @param wireGroup  When true the subject carries the legacy `anti-fraud` marker for
     *                   sequence 2 — matching `defsForWirePair`.
     * @return An in-memory Task carrying the fields the projection reads.
     */
    private static Task legacyTask(String taskGroup, Integer sequence, Boolean closed,
            Boolean wireGroup) {
        String subject = wireGroup && sequence == 2
            ? 'Call title company to verbally verify wiring instructions (anti-fraud)'
            : (wireGroup
                ? 'Send wire request to accounting with verified instructions'
                : (sequence == 1 ? A1_WIRE_SUBJECT : 'Receive critical dates from title company'));
        // 🔴 JSON.deserialize, NOT a field-assignment constructor. `IsClosed` is DERIVED from
        // `Status` and is not writeable, and `LastModifiedById` / `LastModifiedDate` are audit
        // fields that require "Set Audit Fields upon Record Creation". Assigning any of the three
        // in Apex is a COMPILE error when that permission is off - it fails the whole deployment
        // payload, not merely this test. This class performs no DML, so a deserialized Task is
        // exactly as good as a constructed one and carries fields a constructor cannot.
        // ⚠ The sibling `ChecklistMigrationServiceTest` has the same need and solves it the other
        // legitimate way: it inserts a real Task with `Status = Completed` and QUERIES the audit
        // fields back. Use that shape wherever there is a database to query; use this one only
        // where there is not.
        // ⚠ Values are handed to `JSON.serialize` as native types - it renders Date and Datetime
        // in the ISO form the deserializer expects, so no hand-built format string is needed and
        // none should be added.
        Map<String, Object> fields = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Task' },
            'Id' => fakeId(Task.SObjectType, sequence + (taskGroup.length() * 100)),
            'Transaction_Deal__c' => DEAL_ID,
            'Task_Group__c' => taskGroup,
            'Task_Sequence__c' => sequence,
            'Task_Owner_Label__c' => 'Legal',
            'Subject' => subject,
            'Status' => closed ? 'Completed' : 'Not Started',
            'IsClosed' => closed,
            'ActivityDate' => Date.today().addDays(14),
            'Conditional__c' => false,
            'Verbal_Verification_Completed__c' => false,
            'LastModifiedById' => UserInfo.getUserId(),
            'LastModifiedDate' => Datetime.now()
        };
        return (Task) JSON.deserialize(JSON.serialize(fields), Task.class);
    }

    /**
     * @param projection The projection to search.
     * @param letter     Group letter.
     * @param sequence   Item sequence.
     * @return That pending item.
     */
    private static ChecklistMigrationDomain.PendingItem itemAt(
        ChecklistMigrationDomain.Projection projection, String letter, Integer sequence
    ) {
        for (ChecklistMigrationDomain.PendingChecklist pending : projection.checklists) {
            for (ChecklistMigrationDomain.PendingItem item : pending.items) {
                if (item.letter == letter && item.sequence == sequence) {
                    return item;
                }
            }
        }
        Assert.fail('No projected item at ' + letter + sequence);
        return null;
    }

    /**
     * @param projection The projection to search.
     * @param checkName  The check name expected.
     * @param coordinate The coordinate expected (may be blank).
     * @return true when a finding matches both.
     */
    private static Boolean hasFinding(ChecklistMigrationDomain.Projection projection,
            String checkName, String coordinate) {
        for (ChecklistMigrationDomain.Discrepancy finding : projection.discrepancies) {
            if (finding.checkName == checkName && finding.coordinate == coordinate) {
                return true;
            }
        }
        return false;
    }

    /**
     * @param projection The projection.
     * @return Its findings, rendered, so a failed assertion says WHY rather than just false.
     */
    private static String findings(ChecklistMigrationDomain.Projection projection) {
        List<String> rendered = new List<String>();
        for (ChecklistMigrationDomain.Discrepancy finding : projection.discrepancies) {
            rendered.add(String.valueOf(finding.impact) + ' ' + finding.checkName + ' '
                + finding.coordinate + ' tasks=' + finding.taskValue
                + ' items=' + finding.itemValue);
        }
        return 'findings: ' + String.join(rendered, ' | ');
    }

    /**
     * A syntactically valid Id for an unsaved fixture. This class performs no DML, so the Ids
     * never have to resolve — they only have to be distinct and well-formed.
     *
     * @param sobjectType The type to mint for.
     * @param index       A distinguishing number.
     * @return A fake but valid 18-character Id.
     */
    private static Id fakeId(Schema.SObjectType sobjectType, Integer index) {
        String prefix = sobjectType.getDescribe().getKeyPrefix();
        return Id.valueOf(prefix + '0'.repeat(12 - String.valueOf(index).length())
            + String.valueOf(index));
    }
}
