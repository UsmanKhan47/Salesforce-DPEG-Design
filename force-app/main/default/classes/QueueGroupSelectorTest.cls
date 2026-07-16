/**
 * Tests for QueueGroupSelector (SYSTEM_MODE guest/automation lookup). Covers the
 * found path (a seeded queue Group resolved by DeveloperName), plus the not-found
 * and blank-input contracts. Group of Type 'Queue' is insertable via Apex DML, so
 * the found path is seeded directly.
 */
@isTest
private class QueueGroupSelectorTest {

    private static final String QUEUE_DEV_NAME = 'Test_Broker_Portal_Leads_Q';

    @isTest
    static void selectQueueByDeveloperName_found() {
        Group queue = new Group(
            Name = 'Test Broker Portal Leads',
            DeveloperName = QUEUE_DEV_NAME,
            Type = 'Queue'
        );
        insert queue;

        Test.startTest();
        Group result = QueueGroupSelector.selectQueueByDeveloperName(QUEUE_DEV_NAME);
        Test.stopTest();

        Assert.isNotNull(result, 'A queue with the given DeveloperName should resolve');
        Assert.areEqual(queue.Id, result.Id, 'Should return the queue matched by DeveloperName');
    }

    @isTest
    static void selectQueueByDeveloperName_missing_returnsNull() {
        Test.startTest();
        Group result = QueueGroupSelector.selectQueueByDeveloperName('ZZ_Nonexistent_Queue_9x7');
        Test.stopTest();

        Assert.isNull(result, 'An unknown DeveloperName returns null (skip-notification state)');
    }

    @isTest
    static void selectQueueByDeveloperName_blankInput_returnsNull() {
        Test.startTest();
        Group nullResult = QueueGroupSelector.selectQueueByDeveloperName(null);
        Group blankResult = QueueGroupSelector.selectQueueByDeveloperName('   ');
        Test.stopTest();

        Assert.isNull(nullResult, 'Null input returns null');
        Assert.isNull(blankResult, 'Blank input returns null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectRegularAndQueueByDeveloperNames (GroupNotifier — Regular + Queue)
    // ─────────────────────────────────────────────────────────────────────────

    private static final Integer BULK_N = 251;

    /**
     * Bulk: 251 Regular groups resolved in one call by the full set of
     * DeveloperNames. Proves the selector spans the 200-record boundary with a
     * single query (no SOQL-in-loop).
     */
    @isTest
    static void selectRegularAndQueueByDeveloperNames_bulk_returnsAll() {
        Set<String> devNames = new Set<String>();
        List<Group> groups = new List<Group>();
        for (Integer i = 0; i < BULK_N; i++) {
            String dev = 'P4_QG_Bulk_' + i;
            devNames.add(dev);
            groups.add(new Group(Name = 'P4 QG Bulk ' + i, DeveloperName = dev, Type = 'Regular'));
        }
        insert groups;

        Test.startTest();
        List<Group> result = QueueGroupSelector.selectRegularAndQueueByDeveloperNames(devNames);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 Regular groups are returned for the name set');
        Assert.isNotNull(result[0].DeveloperName, 'DeveloperName is populated (the caller keys recipients by it)');
    }

    /**
     * Type-inclusion proof: BOTH a Regular group and a Queue are returned (the
     * method is broader than the Queue-only selectQueueByDeveloperName), and a group
     * whose DeveloperName is NOT in the set is excluded.
     *
     * NOTE (test-coverage limitation): the negative side of the Type filter — a
     * Group of a type OTHER than Regular/Queue — cannot be seeded, because system
     * Group types (Role, RoleAndSubordinates, AllInternalUsers, etc.) are not
     * insertable via Apex DML. The Type IN ('Regular','Queue') clause is therefore
     * proven on its positive (both included) and DeveloperName-filter axes only.
     */
    @isTest
    static void selectRegularAndQueueByDeveloperNames_includesRegularAndQueue_excludesOthers() {
        Group regular = new Group(Name = 'P4 QG Regular', DeveloperName = 'P4_QG_Regular', Type = 'Regular');
        Group queue = new Group(Name = 'P4 QG Queue', DeveloperName = 'P4_QG_Queue', Type = 'Queue');
        Group unqueried = new Group(Name = 'P4 QG Unqueried', DeveloperName = 'P4_QG_Unqueried', Type = 'Regular');
        insert new List<Group>{ regular, queue, unqueried };

        Test.startTest();
        List<Group> result = QueueGroupSelector.selectRegularAndQueueByDeveloperNames(
            new Set<String>{ 'P4_QG_Regular', 'P4_QG_Queue' }
        );
        Test.stopTest();

        Set<Id> ids = new Map<Id, Group>(result).keySet();
        Assert.areEqual(2, result.size(), 'Both the Regular group and the Queue are returned');
        Assert.isTrue(ids.contains(regular.Id), 'The Regular group is included');
        Assert.isTrue(ids.contains(queue.Id), 'The Queue is included');
        Assert.isFalse(ids.contains(unqueried.Id), 'A group not named in the set is excluded by the DeveloperName filter');
    }

    @isTest
    static void selectRegularAndQueueByDeveloperNames_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<Group> nullResult = QueueGroupSelector.selectRegularAndQueueByDeveloperNames(null);
        List<Group> emptyResult = QueueGroupSelector.selectRegularAndQueueByDeveloperNames(new Set<String>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }
}
