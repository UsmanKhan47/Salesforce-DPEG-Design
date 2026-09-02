/**
 * Pins `ChecklistMigrationAuditService` - the Phase 4 M2 reconciliation report that GATES CUTOVER.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE POINT OF THIS CLASS IS THE DISAGREEING DEAL, NOT THE AGREEING ONE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * A report only ever exercised against data that agrees proves nothing - it would pass just as
 * happily if `compare` returned an empty list every time. So the tests below MUTATE a migrated
 * deal so the two models genuinely disagree, and then assert what the report SAYS about it: the
 * check name, the coordinate, and the verdict line. `rendersCleanAndBlockedDifferently` is the
 * discriminator that stops the whole class passing vacuously.
 *
 * ⚠ AND THE EMPTY CASE MUST READ `BLOCKED`, NOT `CLEAR`. A reconciliation asked about no deals
 * has checked nothing, and "nothing was checked" must never render as a pass - that is how a
 * cutover gets approved on a report nobody noticed was empty.
 *
 * ⚠ ASCII-ONLY OUTPUT is asserted, not assumed: the report is read out of an Apex debug log where
 * non-ASCII renders unpredictably, and the same constants would be unusable in an `addError`,
 * which HTML-escapes.
 *
 * ⚠ Every content-bearing test uses a MIGRATED deal, so the report runs in PERSISTED mode - the
 * mode that actually gates cutover. `explainsWhyARefusedDealWasNotMigrated` covers the PROJECTED
 * mode, which is the only thing that turns a flag that did not flip into a diagnosis.
 *
 * @see force-app/main/default/classes/ChecklistMigrationAuditService.cls
 */
@isTest
private class ChecklistMigrationAuditServiceTest {

    private static final String GROUP_B = 'B. Earnest Money Wire';
    private static final String WIRE_SUBJECT =
        'Call title company to verbally verify wiring instructions (anti-fraud)';
    private static final String GATED_SUBJECT =
        'Send wire request to accounting with verified instructions';

    @TestSetup
    static void setupTestData() {
        TestDataFactory.createTransactionsOnChecklistModel(2, true);
    }

    @isTest
    static void reportsCleanAndClearsCutover_WhenTheModelsAgree() {
        Id dealId = migratedDeal();

        Test.startTest();
        List<ChecklistMigrationAuditService.DealVerdict> verdicts =
            ChecklistMigrationAuditService.compare(new List<Id>{ dealId });
        String report = ChecklistMigrationAuditService.format(verdicts);
        Test.stopTest();

        Assert.areEqual('PERSISTED', verdicts[0].mode,
            'A migrated deal must be compared against the rows actually in the database - that is '
            + 'the mode that gates cutover.');
        Assert.isTrue(verdicts[0].isClean(), report);
        Assert.isTrue(report.contains('CUTOVER: CLEAR'),
            'The last line is the whole answer: ' + report);
    }

    /**
     * 🔴 THE DISCRIMINATOR. One item is flipped to Completed while its Task stays open, so the two
     * models genuinely disagree. The report must NAME the check AND the coordinate, and the
     * verdict must flip.
     */
    @isTest
    static void namesTheCheckAndTheCoordinate_WhenAnItemStatusDisagrees() {
        Id dealId = migratedDeal();
        // ⚠ B2, NOT B3. B3 carries Blocked_By__c pointing at an OPEN B2, so branch (A) of the
        // wire gate would REFUSE this update and the test would die on a DmlException instead of
        // producing the disagreement it is trying to report on. B2 is ungated, so mutating it
        // creates a genuine model divergence without tripping the control under test.
        // 🔴 A FRESHLY CONSTRUCTED SPARSE ROW, NOT THE QUERIED ONE. See mutateFlag.
        mutateFlag(itemAt(dealId, 2).Id, ChecklistItemDomain.FLAG_COMPLETED);

        Test.startTest();
        List<ChecklistMigrationAuditService.DealVerdict> verdicts =
            ChecklistMigrationAuditService.compare(new List<Id>{ dealId });
        String report = ChecklistMigrationAuditService.format(verdicts);
        Test.stopTest();

        Assert.isFalse(verdicts[0].isClean(), 'The models disagree: ' + report);
        Assert.isTrue(report.contains('STATUS_MISMATCH'),
            'The report must name the CHECK: ' + report);
        Assert.isTrue(report.contains('B2'),
            'And the COORDINATE. A finding without a coordinate is unactionable, which is the '
            + 'whole reason this report carries no percentages: ' + report);
        Assert.isTrue(report.contains('CUTOVER: BLOCKED'),
            'And a disagreement must block the cutover: ' + report);
    }

    /**
     * A counter disagreement must be named PER COUNTER with BOTH values, not summarised. The wire
     * counter is the one that matters most - a silent zero there is the RISK 1 failure.
     */
    @isTest
    static void namesTheCounterAndBothValues_WhenACounterDisagrees() {
        Id dealId = migratedDeal();
        // Sparse row, same reasoning as mutateFlag - never re-save the queried record.
        update new Checklist_Item__c(
            Id = itemAt(dealId, 2).Id, Verbal_Verification_Completed__c = true);

        Test.startTest();
        List<ChecklistMigrationAuditService.DealVerdict> verdicts =
            ChecklistMigrationAuditService.compare(new List<Id>{ dealId });
        String report = ChecklistMigrationAuditService.format(verdicts);
        Test.stopTest();

        Assert.isFalse(verdicts[0].isClean(), 'The wire counters now differ: ' + report);
        Assert.isTrue(report.contains('Wire_Open_Risks__c'),
            'The report must name the exact counter field: ' + report);
        Assert.isTrue(report.contains('tasks=1') && report.contains('items=0'),
            'And BOTH sides of the disagreement, so the reader does not have to go and look them '
            + 'up: ' + report);
    }

    /**
     * PROJECTED mode. A deal the M1 gate refused never flips its flag, so without this mode the
     * only evidence is a flag that did not move. This is what turns that into a diagnosis.
     */
    @isTest
    static void explainsWhyARefusedDealWasNotMigrated() {
        Transaction__c deal = dealAt(0);
        insert new List<Task>{
            buildTask(deal.Id, 2, WIRE_SUBJECT, false),
            buildTask(deal.Id, 9, 'An orphan task with no definition', false)
        };
        applyDefinitionOverrides();

        Test.startTest();
        List<ChecklistMigrationAuditService.DealVerdict> verdicts =
            ChecklistMigrationAuditService.compare(new List<Id>{ deal.Id });
        String report = ChecklistMigrationAuditService.format(verdicts);
        Test.stopTest();

        Assert.areEqual('PROJECTED', verdicts[0].mode,
            'An un-migrated deal is compared against a fresh projection.');
        Assert.isFalse(verdicts[0].isClean(), report);
        Assert.isTrue(report.contains('NO_DEFINITION') && report.contains('B9'),
            'It must say WHICH coordinate the M1 gate choked on: ' + report);
    }

    /**
     * 🔴 THE VACUOUS-PASS GUARD FOR THIS WHOLE CLASS. If `format` rendered the same trailer
     * regardless of content, every other assertion here would be meaningless. Two runs over
     * genuinely different data must produce genuinely different verdicts.
     */
    @isTest
    static void rendersCleanAndBlockedDifferently() {
        Id dealId = migratedDeal();
        String clean = ChecklistMigrationAuditService.format(
            ChecklistMigrationAuditService.compare(new List<Id>{ dealId }));

        // ⚠ B2, NOT B3. B3 carries Blocked_By__c pointing at an OPEN B2, so branch (A) of the
        // wire gate would REFUSE this update and the test would die on a DmlException instead of
        // producing the disagreement it is trying to report on. B2 is ungated, so mutating it
        // creates a genuine model divergence without tripping the control under test.
        // 🔴 A FRESHLY CONSTRUCTED SPARSE ROW, NOT THE QUERIED ONE. See mutateFlag.
        mutateFlag(itemAt(dealId, 2).Id, ChecklistItemDomain.FLAG_COMPLETED);

        Test.startTest();
        String blocked = ChecklistMigrationAuditService.format(
            ChecklistMigrationAuditService.compare(new List<Id>{ dealId }));
        Test.stopTest();

        Assert.isTrue(clean.contains('CUTOVER: CLEAR'), 'Baseline: ' + clean);
        Assert.isTrue(blocked.contains('CUTOVER: BLOCKED'), 'Mutated: ' + blocked);
        Assert.areNotEqual(clean, blocked,
            'The report must actually depend on the data. If these are equal the formatter is '
            + 'ignoring its input and every other assertion in this class is vacuous.');
    }

    /** Nothing checked must never read as a pass. */
    @isTest
    static void blocksCutover_WhenNoDealsWereSupplied() {
        Test.startTest();
        String report = ChecklistMigrationAuditService.format(
            new List<ChecklistMigrationAuditService.DealVerdict>());
        Test.stopTest();

        Assert.isTrue(report.contains('CUTOVER: BLOCKED'),
            'An empty report has CHECKED NOTHING, and that must not render as a pass: ' + report);
        Assert.isFalse(report.contains('CUTOVER: CLEAR'), 'And must not read CLEAR: ' + report);
    }

    /** The same rule for a null verdict list. Separate input, separate test. */
    @isTest
    static void blocksCutover_WhenVerdictsAreNull() {
        Test.startTest();
        String report = ChecklistMigrationAuditService.format(null);
        Test.stopTest();

        Assert.isTrue(report.contains('CUTOVER: BLOCKED'), 'Null in, BLOCKED out: ' + report);
    }

    @isTest
    static void returnsNoVerdicts_WhenInputIsNull() {
        Test.startTest();
        List<ChecklistMigrationAuditService.DealVerdict> verdicts =
            ChecklistMigrationAuditService.compare(null);
        Test.stopTest();

        Assert.areEqual(0, verdicts.size(), 'A null input produces no verdicts.');
    }

    /**
     * The cap THROWS rather than truncating. A reconciliation that quietly reported on fewer deals
     * than it was asked about is worse than none, because the missing deals read as absent and
     * therefore clean.
     */
    @isTest
    static void throws_WhenAskedForMoreDealsThanOneRunCanHold() {
        List<Id> tooMany = new List<Id>();
        Id dealId = dealAt(0).Id;
        for (Integer i = 0; i < 26; i++) {
            tooMany.add(dealId);
        }

        Test.startTest();
        Boolean threw = false;
        try {
            ChecklistMigrationAuditService.compare(tooMany);
            Assert.fail('Expected AuditScopeException above 25 deals.');
        } catch (ChecklistMigrationAuditService.AuditScopeException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('HEAP'),
                'The message must say WHY the cap exists, or the next reader raises it: '
                + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The cap must be enforced by a throw, never by a silent truncate.');
    }

    @isTest
    static void reportsNotVisible_WhenTheSelectorReturnsNoRow() {
        Transaction__c deal = dealAt(0);
        Id dealId = deal.Id;
        delete deal;

        Test.startTest();
        List<ChecklistMigrationAuditService.DealVerdict> verdicts =
            ChecklistMigrationAuditService.compare(new List<Id>{ dealId });
        String report = ChecklistMigrationAuditService.format(verdicts);
        Test.stopTest();

        Assert.isFalse(verdicts[0].isClean(), 'An unreadable deal is not a clean deal.');
        Assert.isTrue(report.contains('NOT_VISIBLE') && report.contains('NOT VISIBLE 1'),
            'It must be named AND counted in the trailer, because sharing is the most likely way '
            + 'a run silently covers fewer deals than it claims: ' + report);
    }

    /** The report is read from a debug log and shares its constants with error surfaces. */
    @isTest
    static void rendersAsciiOnly() {
        Id dealId = migratedDeal();

        Test.startTest();
        String report = ChecklistMigrationAuditService.format(
            ChecklistMigrationAuditService.compare(new List<Id>{ dealId }));
        Test.stopTest();

        Assert.isTrue(Pattern.matches('(?s)[\\x20-\\x7E\\n]*', report),
            'Non-ASCII in this report renders unpredictably in an Apex debug log, and addError '
            + 'HTML-escapes the same constants. Report was: ' + report);
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────

    /**
     * @return A deal migrated through the real service, so the report is compared against rows
     *         the production code actually produced rather than a hand-built fixture that could
     *         diverge from it.
     */
    private static Id migratedDeal() {
        Transaction__c deal = dealAt(0);
        insert new List<Task>{
            buildTask(deal.Id, 2, WIRE_SUBJECT, false),
            buildTask(deal.Id, 3, GATED_SUBJECT, false)
        };
        applyDefinitionOverrides();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Assert.areEqual('MIGRATED', results[0].outcome,
            'The audit fixture must actually migrate, or every assertion about PERSISTED mode is '
            + 'testing the wrong branch.');
        return deal.Id;
    }

    /**
     * Installs the CMDT overrides on BOTH consumers.
     *
     * 🔴 THIS COMMENT WAS FALSE UNTIL THE AUDIT SEAM EXISTED, AND THE TESTS PASSED ANYWAY.
     * `ChecklistMigrationAuditService` called the two providers DIRECTLY, so five tests migrated
     * with this fixture definition set and then reconciled against the org LIVE CMDT - passing
     * only because the loader happened to have been run. On an org where it has not, every
     * coordinate reports NO_DEFINITION and the CLEAN tests go red for an unrelated reason.
     * ⚠ BOTH pairs must be set. Setting only the service pair reintroduces exactly that bug.
     */
    private static void applyDefinitionOverrides() {
        List<Task_Group_Def__mdt> groups = new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'B', Group_Name__c = 'Earnest Money Wire',
                Owner_Label__c = 'CFO', Sequence__c = 2, Stage__c = 'Open Contract',
                Conditional__c = false)
        };
        List<Transaction_Task_Def__mdt> defs = new List<Transaction_Task_Def__mdt>{
            new Transaction_Task_Def__mdt(Group_Letter__c = 'B', Sequence__c = 2,
                Subject__c = WIRE_SUBJECT, Owner_Label__c = 'CFO', Is_Critical__c = true,
                Is_Wire_Verification__c = true),
            new Transaction_Task_Def__mdt(Group_Letter__c = 'B', Sequence__c = 3,
                Subject__c = GATED_SUBJECT, Owner_Label__c = 'CFO', Is_Critical__c = false,
                Is_Wire_Verification__c = false, Blocked_By_Sequence__c = 2)
        };
        ChecklistMigrationService.groupDefsOverride = groups;
        ChecklistMigrationService.taskDefsOverride = defs;
        ChecklistMigrationAuditService.groupDefsOverride = groups;
        ChecklistMigrationAuditService.taskDefsOverride = defs;
    }

    /**
     * @param dealId   Parent deal.
     * @param sequence Task_Sequence__c.
     * @param subject  Subject.
     * @param closed   Whether it is Completed.
     * @return An unsaved checklist Task in group B.
     */
    private static Task buildTask(Id dealId, Integer sequence, String subject, Boolean closed) {
        return new Task(
            Subject = subject,
            Status = closed ? 'Completed' : 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today().addDays(14),
            Transaction_Deal__c = dealId,
            Task_Group__c = GROUP_B,
            Task_Sequence__c = sequence,
            Task_Owner_Label__c = 'CFO',
            Conditional__c = false,
            Verbal_Verification_Completed__c = false
        );
    }

    /** @param index Position in the deterministic ordering. @return That scaffold deal. */
    private static Transaction__c dealAt(Integer index) {
        List<Transaction__c> deals = [
            SELECT Id, Checklist_Fanned_Out__c
            FROM Transaction__c
            ORDER BY Contract_Value__c
        ];
        return deals[index];
    }


    /**
     * Flips one item to a done flag by UPDATING A FRESHLY CONSTRUCTED SPARSE ROW, never by
     * re-saving the record `itemAt` returned.
     *
     * 🔴 THE THREE RE-SAVES THIS REPLACES FAILED WITH
     * `System.DmlException: Operation failed due to fields being inaccessible on Sobject
     * Checklist_Item__c` on a BARE `update` (2026-09-02) - which should be impossible, because a
     * bare `update` does not enforce FLS. The bare-update path was traced end to end and contains
     * NO FLS-enforced DML on this object: the before contexts are in-memory
     * (`ChecklistItemDomain.stampCompletion`) plus a SYSTEM_MODE selector read
     * (`ChecklistItemPrerequisiteService`), the after context is `ChecklistRollupService`, whose
     * writes are SYSTEM_MODE, and the one `AccessLevel.USER_MODE` update on this object
     * (`ChecklistItemService.save`) is PRIVATE and reachable only from the LWC service methods.
     *
     * ⚠ SHARING WAS PROPOSED AS THE REAL MECHANISM AND IS REFUTED — TWICE, INDEPENDENTLY. The
     * hypothesis: both master-detail links carry `writeRequiresMasterRead=false`, which is the
     * STRICTER setting (read AND WRITE on the master), so editing an item needs Edit sharing on the
     * `Transaction__c` two hops up, and `Transaction__c` is Private OWD. The inversion is real and
     * worth knowing. It is not what fails here:
     *   1. THAT SETTING GOVERNS CREATE, EDIT **AND DELETE** IDENTICALLY. `migratedDeal()` inserts
     *      `Checklist__c` and `Checklist_Item__c` under this very deal, moments earlier, in the
     *      same transaction, and asserts the result is MIGRATED. Those inserts run
     *      `AccessLevel.SYSTEM_MODE`, which lifts CRUD/FLS and NEVER sharing. If the running
     *      principal lacked write sharing on the deal, step 1 of the migration would have failed
     *      first. It did not, so the principal has it.
     *   2. THE RUNNING USER OWNS THE DEAL. `TestDataFactory.createTransactionsOnChecklistModel`
     *      sets no `OwnerId`, so the `@TestSetup` insert leaves the running user as owner, and an
     *      owner of a Private-OWD record has full access unconditionally.
     * ⚠ THE PERSONA CONTRAST DOES NOT SUPPORT IT EITHER. `ChecklistItemServiceTest` (25 green) has
     * ZERO `System.runAs` — it writes as the running user exactly as this class does. Only
     * `ChecklistControllerTest` uses personas, in 3 of its 29 methods.
     * ⚠ ALSO CHECKED AND ELIMINATED: a non-updateable field riding along in the payload.
     * `Checklist_Item__c` has NO formula and NO roll-up fields, and every column `itemAt` selects
     * is Number / Picklist / Lookup / Checkbox / Date — all writeable.
     *
     * ⇒ 🟢 CONFIRMED 2026-09-02, EXPERIMENT CLOSED. The cause is the PAYLOAD SHAPE of a re-saved
     * QUERIED record. The single-variable run returned BRANCH 1: this class went 12/12 with
     * `itemAt` STILL selecting `Checklist__r.Group_Letter__c`, so THE PARENT TRAVERSAL IS
     * EXONERATED and the second probe is not needed - do not run it. Four candidates, three
     * eliminated by evidence and the fourth isolated by an experiment kept deliberately to one
     * variable. This block is now the record of a FINISHED investigation, not an open one.
     * ⚠ WHAT ACTUALLY DIFFERS, MEASURED AGAINST THE GREEN SIBLINGS: `ChecklistItemServiceTest`
     * (25 green) and `ChecklistControllerTest` (29 green) NEVER update a QUERIED
     * `Checklist_Item__c` - every mutation there is an insert of an in-memory row, and the single
     * update in that family (`ChecklistControllerTest:189`) is a freshly constructed sparse
     * sObject. This class was the only place re-saving a record that came back from SOQL, and
     * that SOQL traverses a parent (`Checklist__r.Group_Letter__c`), so the payload carries the
     * parent sub-object into the DML. This helper adopts the sibling pattern, which is also
     * better hygiene: a sparse update states exactly the field under test.
     *
     * 🔴 THE MECHANISM IS NARROWED, NOT PROVEN, AND THE EXPERIMENT IS DELIBERATELY SINGLE-VARIABLE.
     * `itemAt` STILL selects `Checklist__r.Group_Letter__c` (which no caller reads - it is dead
     * weight and was left in ON PURPOSE), so if these tests go green the isolated cause is the
     * PAYLOAD SHAPE, not the traversal. If they still fail, the next probe is to drop that
     * traversal from `itemAt` and re-run - that discriminates "queried record carries its parent
     * into the DML" from "traversal in the SELECT" without changing anything else.
     *
     * @param itemId The item to flip.
     * @param flag   The `Flag__c` value to set.
     */
    private static void mutateFlag(Id itemId, String flag) {
        update new Checklist_Item__c(Id = itemId, Flag__c = flag);
    }

    /**
     * @param dealId   The deal.
     * @param sequence The item sequence wanted.
     * @return That persisted item. ⚠ CALLERS READ ITS `Id` AND ASSERT ON IT - THEY DO NOT MUTATE
     *         AND RE-SAVE IT; see `mutateFlag` for why. `Checklist__r.Group_Letter__c` is
     *         deliberately still selected and deliberately unread - it is the second variable in
     *         the isolation described there, and removing it now would confound the experiment.
     */
    private static Checklist_Item__c itemAt(Id dealId, Integer sequence) {
        return [
            SELECT Id, Sequence__c, Flag__c, Blocked_By__c, Is_Prerequisite_Met__c,
                   Is_Wire_Verification__c, Verbal_Verification_Completed__c, Due_Date__c,
                   Checklist__r.Group_Letter__c
            FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c = :dealId AND Sequence__c = :sequence
        ];
    }
}
