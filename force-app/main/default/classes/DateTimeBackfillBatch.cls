/**
 * DateTimeBackfillBatch
 *
 * D2 of the 8-DateTime migration (ARCHITECTURE.md §1 rule 9). Copies historical
 * data from each legacy `*_Date__c` DateTime field into its correctly-named
 * `*_DateTime__c` twin, for rows created before D1's dual-write existed.
 *
 * Read-old / write-new ONLY. Never touches Status__c or any field the
 * before-save flow `Work_Order_Touch_Sync` reads for its IsNull stamping.
 *
 * Idempotent: copies only where old != null AND new = null, so a partial run
 * is safe to re-run. finish() verifies zero rows remain and throws otherwise —
 * a silent partial backfill is how data goes missing.
 *
 * ── The hard gate ──────────────────────────────────────────────────────────
 * `Work_Order_Touch_Sync` is before-save, create-and-update, with NO entry
 * criteria, so a backfill UPDATE re-fires it on every historical Work Order.
 * The backfill is only safe because the flow's stamping rules are no-ops on the
 * rows it would act on. run() PROVES that with two pre-flight canaries and
 * aborts before any DML if either fails. Do not remove them.
 *
 * ── `without sharing` — deliberate, justified per ARCHITECTURE.md §2 ─────────
 * A data migration must SEE and REPAIR every historical row regardless of the
 * operator's record visibility. Under `with sharing`, start()'s scope, both
 * canary COUNT()s, and finish()'s remaining-count would each run in the
 * operator's sharing: rows the operator cannot see would be silently skipped by
 * execute() AND invisible to finish()'s count — so finish() would report
 * "0 remaining" and pass while unbackfilled rows survive, defeating the entire
 * loud-fail guarantee. `without sharing` runs the completeness check in system
 * mode, which is the only mode in which it is sound.
 *
 * ── SOQL is intentionally inline, not in a Selector — justified ──────────────
 * §2 lists Batch as its own layer; the layering rule allows inline SOQL here
 * with written justification (this note). A `WITH USER_MODE` Selector would be
 * actively WRONG for a migration — it enforces the running user's FLS/sharing
 * and would hide the exact rows this job exists to repair. All queries run in
 * system mode (legacy default) by design. They carry no user input: every field
 * and object name comes only from the hardcoded BACKFILL map, so there is no
 * SOQL-injection surface.
 *
 * @example  DateTimeBackfillBatch.run();   // guarded entry point — use this
 */
public without sharing class DateTimeBackfillBatch implements Database.Batchable<SObject>, Database.Stateful {

    // ─── Field map: object → (legacy field → new field) ──────────────────────
    // Hardcoded constants only — the dynamic SOQL below carries no user input.
    private static final Map<String, Map<String, String>> BACKFILL = new Map<String, Map<String, String>>{
        'Work_Order__c' => new Map<String, String>{
            'Reported_Date__c'      => 'Reported_DateTime__c',
            'Completed_Date__c'     => 'Completed_DateTime__c',
            'First_Touched_Date__c' => 'First_Touched_DateTime__c'
        },
        'Deal_Message__c'        => new Map<String, String>{ 'Entry_Date__c' => 'Entry_DateTime__c' },
        'Lease_Activity__c'      => new Map<String, String>{ 'Entry_Date__c' => 'Entry_DateTime__c' },
        'Renewal_Activity__c'    => new Map<String, String>{ 'Entry_Date__c' => 'Entry_DateTime__c' },
        'Work_Order_Activity__c' => new Map<String, String>{ 'Entry_Date__c' => 'Entry_DateTime__c' }
    };

    private final String objectApi;
    private final Map<String, String> oldToNew;
    private Integer copied = 0;

    public DateTimeBackfillBatch(String objectApi, Map<String, String> oldToNew) {
        this.objectApi = objectApi;
        this.oldToNew  = oldToNew;
    }

    // ─── Guarded entry point ─────────────────────────────────────────────────
    /**
     * Runs the two hard-gate canaries, then enqueues one batch per object.
     * Aborts before any DML if either canary is non-zero — that count is itself
     * a data-integrity finding about the org.
     */
    public static void run() {
        assertBackfillSafe();
        // BACKFILL has exactly 5 objects, at the concurrent Apex batch ceiling (5).
        // Fine as-is; if a 6th object is ever added, enqueue in waves or chain in
        // finish() rather than looping all at once.
        for (String obj : BACKFILL.keySet()) {
            Database.executeBatch(new DateTimeBackfillBatch(obj, BACKFILL.get(obj)), 200);
        }
    }

    /**
     * The hard gate, extracted so it is testable without launching a batch
     * (a test method may call Database.executeBatch only once). Throws if either
     * canary is non-zero — i.e. if any Work Order is in a state where the
     * backfill UPDATE would cause Work_Order_Touch_Sync to stamp NOW().
     */
    @TestVisible
    private static void assertBackfillSafe() {
        // Canary 1 — Needs_First_Touch would stamp NOW() on any non-New row
        // whose old First_Touched_Date__c is null.
        Integer c1 = [
            SELECT COUNT()
            FROM Work_Order__c
            WHERE Status__c != 'New' AND First_Touched_Date__c = null
        ];
        // Canary 2 — Completed_Check would stamp NOW() on any Completed/Closed
        // row whose old Completed_Date__c is null.
        Integer c2 = [
            SELECT COUNT()
            FROM Work_Order__c
            WHERE Status__c IN ('Completed', 'Closed') AND Completed_Date__c = null
        ];
        if (c1 > 0 || c2 > 0) {
            throw new BackfillAbortException(
                'Pre-flight canary failed — backfill would trip Work_Order_Touch_Sync. ' +
                'Needs_First_Touch candidates=' + c1 + ', Completed_Check candidates=' + c2 +
                '. Resolve these rows before backfilling; do not proceed.'
            );
        }
    }

    // ─── Batchable ───────────────────────────────────────────────────────────
    public Database.QueryLocator start(Database.BatchableContext bc) {
        List<String> fields = new List<String>{ 'Id' };
        List<String> conds  = new List<String>();
        for (String oldF : oldToNew.keySet()) {
            String newF = oldToNew.get(oldF);
            fields.add(oldF);
            fields.add(newF);
            conds.add('(' + oldF + ' != null AND ' + newF + ' = null)');
        }
        String q = 'SELECT ' + String.join(fields, ', ') +
                   ' FROM ' + objectApi +
                   ' WHERE ' + String.join(conds, ' OR ');
        return Database.getQueryLocator(q);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        for (SObject rec : scope) {
            Boolean touched = false;
            for (String oldF : oldToNew.keySet()) {
                String newF = oldToNew.get(oldF);
                if (rec.get(oldF) != null && rec.get(newF) == null) {
                    rec.put(newF, rec.get(oldF));
                    touched = true;
                }
            }
            if (touched) copied++;
        }
        update scope;
    }

    public void finish(Database.BatchableContext bc) {
        // Loud-fail contract: zero rows may remain with old populated / new null.
        assertComplete(objectApi, oldToNew);
    }

    /**
     * The loud-fail verification, extracted from finish() so it is testable
     * directly. finish() and start() share a predicate, so a normal run never
     * leaves rows behind — the only way to exercise this THROW is to invoke it
     * against a deliberately-unfinished row. Throws if any (old != null AND
     * new = null) row survives — a silent partial backfill is how data goes
     * missing. Runs in system mode (see the class-header SOQL justification).
     * @param objectApi The object to verify.
     * @param oldToNew  Legacy field -> new field map to check.
     * @throws BackfillAbortException when any field still has rows to copy.
     */
    @TestVisible
    private static void assertComplete(String objectApi, Map<String, String> oldToNew) {
        for (String oldF : oldToNew.keySet()) {
            String newF = oldToNew.get(oldF);
            Integer remaining = Database.countQuery(
                'SELECT COUNT() FROM ' + objectApi +
                ' WHERE ' + oldF + ' != null AND ' + newF + ' = null'
            );
            if (remaining > 0) {
                throw new BackfillAbortException(
                    'Backfill incomplete on ' + objectApi + '.' + newF +
                    ': ' + remaining + ' rows still need the copy.'
                );
            }
        }
    }

    public class BackfillAbortException extends Exception {}
}
