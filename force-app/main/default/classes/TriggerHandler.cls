/**
 * Base class for the DPEG one-trigger-per-object pattern (ARCHITECTURE.md §2,
 * .claude/rules/apex-layering-rule.md "TriggerHandler Base Class Rule").
 *
 * Every custom trigger in this org is exactly one line:
 *
 *     new <Object>TriggerHandler().run();
 *
 * On construction the base captures the running trigger context and its
 * collections once. run() then dispatches to the single context method that
 * matches Trigger.operationType. Concrete handlers extend this class and
 * override ONLY the contexts they act on; every context method is an empty
 * virtual by default, so an after-update-only handler overrides just
 * afterUpdate() and inherits safe no-ops for the other six contexts.
 *
 * Bulk-safe by construction: the base performs no per-record work. It hands the
 * whole Trigger.new / Trigger.old collection to the context method, so
 * subclasses always operate on Lists — never single records.
 *
 * Sharing: with sharing per the project's non-negotiable standard. run() and the
 * context methods therefore execute in the caller's sharing context. Services
 * invoked downstream declare their own sharing, which this router does not alter.
 */
public with sharing virtual class TriggerHandler {

    /**
     * Trigger operation captured at construction. @TestVisible so a unit test can
     * drive each dispatch branch of run() directly, without needing a live DML in
     * every one of the seven contexts.
     */
    @TestVisible
    protected System.TriggerOperation operation;

    /** Trigger.new, captured once. Available to subclasses as a List<SObject>. */
    @TestVisible
    protected List<SObject> newList;

    /** Trigger.old, captured once. Available to subclasses as a List<SObject>. */
    @TestVisible
    protected List<SObject> oldList;

    /** Trigger.newMap, captured once. */
    @TestVisible
    protected Map<Id, SObject> newMap;

    /** Trigger.oldMap, captured once. */
    @TestVisible
    protected Map<Id, SObject> oldMap;

    /**
     * Captures the current trigger context and collections. Invoked implicitly by
     * every concrete handler's zero-arg construction inside its trigger.
     */
    public TriggerHandler() {
        this.operation = Trigger.operationType;
        this.newList = Trigger.new;
        this.oldList = Trigger.old;
        this.newMap = Trigger.newMap;
        this.oldMap = Trigger.oldMap;
    }

    /**
     * Dispatches to the context method matching the captured trigger operation.
     * A no-op when invoked outside a trigger (operation is null).
     */
    public void run() {
        if (operation == null) {
            return;
        }
        switch on operation {
            when BEFORE_INSERT {
                beforeInsert();
            }
            when BEFORE_UPDATE {
                beforeUpdate();
            }
            when BEFORE_DELETE {
                beforeDelete();
            }
            when AFTER_INSERT {
                afterInsert();
            }
            when AFTER_UPDATE {
                afterUpdate();
            }
            when AFTER_DELETE {
                afterDelete();
            }
            when AFTER_UNDELETE {
                afterUndelete();
            }
        }
    }

    /** Override to act on before insert. */
    protected virtual void beforeInsert() {
    }

    /** Override to act on before update. */
    protected virtual void beforeUpdate() {
    }

    /** Override to act on before delete. */
    protected virtual void beforeDelete() {
    }

    /** Override to act on after insert. */
    protected virtual void afterInsert() {
    }

    /** Override to act on after update. */
    protected virtual void afterUpdate() {
    }

    /** Override to act on after delete. */
    protected virtual void afterDelete() {
    }

    /** Override to act on after undelete. */
    protected virtual void afterUndelete() {
    }
}
