/**
 * Unit tests for the TriggerHandler base dispatcher. These exercise run()'s
 * seven dispatch branches and its outside-trigger no-op directly, without a live
 * DML in every context, by driving the @TestVisible operation seam through a
 * test-only subclass. Object-specific routing is proven by the per-handler test
 * classes.
 */
@isTest
private class TriggerHandlerTest {

    /**
     * Records which context method run() dispatched to. Overrides every context
     * so each of the seven switch branches has an observable effect.
     */
    private class RecordingHandler extends TriggerHandler {
        public String lastContext = 'none';

        public void forceOperation(System.TriggerOperation op) {
            this.operation = op;
        }

        protected override void beforeInsert() {
            lastContext = 'beforeInsert';
        }
        protected override void beforeUpdate() {
            lastContext = 'beforeUpdate';
        }
        protected override void beforeDelete() {
            lastContext = 'beforeDelete';
        }
        protected override void afterInsert() {
            lastContext = 'afterInsert';
        }
        protected override void afterUpdate() {
            lastContext = 'afterUpdate';
        }
        protected override void afterDelete() {
            lastContext = 'afterDelete';
        }
        protected override void afterUndelete() {
            lastContext = 'afterUndelete';
        }
    }

    /** A handler that overrides nothing — proves the base virtuals are safe no-ops. */
    private class BareHandler extends TriggerHandler {
        public void forceOperation(System.TriggerOperation op) {
            this.operation = op;
        }
    }

    @isTest
    static void run_DispatchesEachOperationToItsContextMethod() {
        // Given: the mapping of every trigger operation to its context method name.
        Map<System.TriggerOperation, String> expectedByOperation =
            new Map<System.TriggerOperation, String>{
                System.TriggerOperation.BEFORE_INSERT => 'beforeInsert',
                System.TriggerOperation.BEFORE_UPDATE => 'beforeUpdate',
                System.TriggerOperation.BEFORE_DELETE => 'beforeDelete',
                System.TriggerOperation.AFTER_INSERT => 'afterInsert',
                System.TriggerOperation.AFTER_UPDATE => 'afterUpdate',
                System.TriggerOperation.AFTER_DELETE => 'afterDelete',
                System.TriggerOperation.AFTER_UNDELETE => 'afterUndelete'
            };

        // When / Then: run() routes each operation to exactly its context method.
        for (System.TriggerOperation op : expectedByOperation.keySet()) {
            RecordingHandler handler = new RecordingHandler();
            handler.forceOperation(op);
            handler.run();
            Assert.areEqual(
                expectedByOperation.get(op),
                handler.lastContext,
                'run() should dispatch ' + op + ' to ' + expectedByOperation.get(op)
            );
        }
    }

    @isTest
    static void run_IsNoOp_WhenNoTriggerOperation() {
        // Given: a handler constructed outside a trigger — operation is null.
        RecordingHandler handler = new RecordingHandler();

        // When
        handler.run();

        // Then
        Assert.areEqual(
            'none',
            handler.lastContext,
            'run() must dispatch nothing when there is no trigger operation'
        );
    }

    @isTest
    static void baseContextMethods_AreNoOps_ForEveryOperation() {
        // Given / When / Then: a handler that overrides nothing runs cleanly in
        // every context, covering each empty base virtual body.
        for (System.TriggerOperation op : new List<System.TriggerOperation>{
            System.TriggerOperation.BEFORE_INSERT,
            System.TriggerOperation.BEFORE_UPDATE,
            System.TriggerOperation.BEFORE_DELETE,
            System.TriggerOperation.AFTER_INSERT,
            System.TriggerOperation.AFTER_UPDATE,
            System.TriggerOperation.AFTER_DELETE,
            System.TriggerOperation.AFTER_UNDELETE
        }) {
            BareHandler handler = new BareHandler();
            handler.forceOperation(op);
            handler.run();
        }
        Assert.isTrue(true, 'Default virtual context methods are safe no-ops in every context');
    }
}
