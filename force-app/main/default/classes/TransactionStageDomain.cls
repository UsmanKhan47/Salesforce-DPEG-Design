/**
 * Per-object business rules for `Transaction__c`'s LIFECYCLE ORDER — which stage follows which,
 * and therefore what counts as a FORWARD move. Plus the one display helper the stage gate needs.
 *
 * layer=domain (`.claude/rules/apex-layering-rule.md`, "Domain Purity Rule"). ZERO SOQL and ZERO
 * DML at any record count. Every method here is a pure function over primitives — no describe, no
 * Custom Metadata, no static state that survives a call. The gate that NEEDS a database read is
 * `TransactionStageGateService`, which is a service precisely because it needs one.
 *
 * =============================================================================================
 * THIS IS THE THIRD COPY OF THE STAGE ORDER IN THIS ORG, AND THAT IS A DELIBERATE, PINNED
 * DECISION - NOT AN OVERSIGHT. READ THIS BEFORE EDITING THE LIST.
 * =============================================================================================
 * The order already existed twice before this class:
 *   1. `RecordStageAdvanceService.TRANSACTION_NEXT_STAGE` - the map the four `Move_to_*` quick
 *      actions walk. Its own header says the order "IS A USER DECISION, NOT A DERIVATION, AND IT
 *      IS THE ONE THING HERE THAT CANNOT BE WRONG QUIETLY", confirmed by the user at Gate 1 on
 *      2026-08-12 against the live picklist.
 *   2. The `Transaction__c.Stage__c` picklist value set itself - `restricted=true`,
 *      `sorted=false`, so the AUTHORED element order is the real order.
 *
 * A third copy was chosen over deriving from either at runtime, for two reasons that are about
 * blast radius and about safety, not about convenience:
 *   - NOT from `RecordStageAdvanceService`: that class is ~2,600 lines and dispatches eight
 *     objects. Making a live safety gate depend on its internals at runtime widens the blast
 *     radius of every future edit to it.
 *   - NOT from `Schema` describe at runtime: picklist element order is re-orderable in Setup by
 *     anyone with Customize Application, and a re-order would SILENTLY INVERT this gate rather
 *     than fail. `getPicklistValues()` also returns inactive values, so the list would grow
 *     entries nothing else knows about.
 *
 * WHAT KEEPS THE THIRD COPY HONEST IS A TEST, NOT A COMMENT. `TransactionStageDomainTest` must
 * cross-check `stageOrder()` against BOTH of the other two sources - the
 * `RecordStageAdvanceService.TRANSACTION_NEXT_STAGE` map walked end to end (it is `@TestVisible`
 * for exactly and only this purpose), and the ACTIVE `Transaction__c.Stage__c` describe values in
 * their authored order. If that test is ever deleted or weakened, this class becomes an
 * unpinned duplicate of a user decision and the gate can invert without anything going red.
 *
 * =============================================================================================
 * UNRECOGNISED VALUES FAIL OPEN, ON PURPOSE
 * =============================================================================================
 * `ordinalOf` returns null for anything not in the list - null, blank, a value someone adds to
 * the picklist without updating this class, or a legacy value such as the retired `Closed Won`
 * (renamed to `Closed` in Setup on 2026-08-28; see `RecordStageAdvanceService`). `isForward` is
 * therefore false whenever either side is unrecognised, so the move is NOT gated.
 *
 * That is the correct direction for THIS control. The gate refuses a user save; a gate that
 * refuses on a value it does not understand would brick a deal with a message nobody can act on,
 * and the refusal would arrive on the picklist edit rather than on the code change that missed it.
 * The cost of failing open is made VISIBLE rather than silent: `TransactionStageGateService`
 * counts these in `lastRunUnknownStageCount`, which a test asserts is zero.
 *
 * @see force-app/main/default/classes/TransactionStageGateService.cls (sole production caller)
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls (source 1 of the order)
 * @see force-app/main/default/objects/Transaction__c/fields/Stage__c.field-meta.xml (source 2)
 * @see agent-output/design-checklist-cutover-and-stage-gate.md B2.3, B3.3, B3.7
 */
public with sharing class TransactionStageDomain {

    /** First stage. The picklist default (`default=true` on the field). */
    public static final String STAGE_OPEN_CONTRACT = 'Open Contract';

    /** Second stage. */
    public static final String STAGE_DUE_DILIGENCE = 'Due Diligence';

    /** Third stage. */
    public static final String STAGE_CLOSING_PREP = 'Closing Prep';

    /**
     * Fourth stage. THE HYPHEN IS LOAD-BEARING. `Post-Closing` is byte-identical on
     * `Transaction__c.Stage__c`, `Checklist__c.Stage__c` and `Checklist_Item__c.Stage__c`, all
     * three of which are restricted picklists, and restriction on this project is a MEASURED
     * DML-enforced fact rather than a UI convention. `Post Closing` (space) is the label used on
     * two FlexiPage tabs and is NOT a value; do not copy it from there.
     */
    public static final String STAGE_POST_CLOSING = 'Post-Closing';

    /**
     * Terminal stage. Renamed from `Closed Won` in Setup on 2026-08-28 - BOTH label and API name.
     * It owns NO checklist group: `Checklist_Item__c.Stage__c` and `Checklist__c.Stage__c` carry
     * only the four non-terminal values. The Post-Closing to Closed hop is therefore gated on the
     * POST-CLOSING items (the stage being LEFT), which is what the gate does by construction.
     */
    public static final String STAGE_CLOSED = 'Closed';

    /**
     * The order. Byte-identical to the `Transaction__c.Stage__c` value set, in its authored order.
     * Private so no caller can mutate a shared static; read it through `stageOrder()`.
     */
    private static final List<String> ORDER = new List<String>{
        STAGE_OPEN_CONTRACT,
        STAGE_DUE_DILIGENCE,
        STAGE_CLOSING_PREP,
        STAGE_POST_CLOSING,
        STAGE_CLOSED
    };

    /**
     * Stage to zero-based position. Built once from `ORDER`, so the two cannot disagree.
     *
     * Apex `Map<String, ...>` lookups are CASE-SENSITIVE even though `==` on Strings is not, so a
     * value differing only in case resolves to null here and the move fails open rather than
     * being mis-ordered. That is deliberate: a restricted picklist cannot store a case variant,
     * so a case mismatch means the caller invented the value, and inventing a value is exactly
     * the case that must not be trusted to be ordered correctly.
     */
    private static final Map<String, Integer> ORDINAL_BY_STAGE = buildOrdinals();

    /**
     * The stage sequence, oldest to newest, as a DEFENSIVE COPY.
     *
     * A copy rather than the backing list because a public static `List` is mutable by every
     * caller in the transaction, and a gate whose ordering can be edited at runtime by an
     * unrelated class is not a gate. The copy is 5 strings; it costs nothing.
     *
     * @return A new `List&lt;String&gt;` of the five stage values in order; never null, never empty.
     * @example
     * List&lt;String&gt; order = TransactionStageDomain.stageOrder();
     */
    public static List<String> stageOrder() {
        return new List<String>(ORDER);
    }

    /**
     * The zero-based position of a stage in the lifecycle.
     *
     * @param stage A `Transaction__c.Stage__c` value; null- and blank-safe.
     * @return 0 through 4, or NULL when the value is not one of the five recognised stages.
     *         A null return is MEANINGFUL and every caller must treat it as "do not order this",
     *         never as position zero.
     * @example
     * Integer position = TransactionStageDomain.ordinalOf(deal.Stage__c);
     */
    public static Integer ordinalOf(String stage) {
        if (String.isBlank(stage)) {
            return null;
        }
        return ORDINAL_BY_STAGE.get(stage);
    }

    /**
     * Whether a value is one of the five recognised stages. Exists so a caller can tell
     * "unrecognised" apart from "backward" without duplicating the null check on `ordinalOf`.
     *
     * @param stage A `Transaction__c.Stage__c` value; null- and blank-safe.
     * @return true only for a recognised value.
     * @example
     * if (!TransactionStageDomain.isKnown(prior.Stage__c)) { unknownStages++; }
     */
    public static Boolean isKnown(String stage) {
        return ordinalOf(stage) != null;
    }

    /**
     * Whether this save moves the deal FORWARD along the lifecycle.
     *
     * True ONLY when both values are recognised AND the new one sits later in the order. So:
     *   - backward (Due Diligence to Open Contract)  -> false. NOT gated, by user decision 3.
     *   - lateral / unchanged                        -> false. Every counter, flag, owner and
     *     rollup write on a deal leaves here, which is what keeps the gate at zero SOQL.
     *   - either side unrecognised or null           -> false. See the fail-open note in the
     *     class header.
     *   - a SKIP (Open Contract straight to Closed)  -> TRUE, and it is gated on the stage being
     *     LEFT. That is correct and intentional: `RecordStageAdvanceService` cannot produce a
     *     skip for this object (it has no explicit-target allow-list, so `advanceTo` is
     *     structurally unreachable), but Data Loader, the API and inline edit all can, and a skip
     *     is exactly the save a completion gate should still have an opinion about.
     *
     * @param priorStage The stored `Stage__c` (`Trigger.oldMap`); null-safe.
     * @param nextStage  The `Stage__c` being saved (`Trigger.new`); null-safe.
     * @return true only for a recognised forward move.
     * @example
     * if (TransactionStageDomain.isForward(prior.Stage__c, deal.Stage__c)) { ... }
     */
    public static Boolean isForward(String priorStage, String nextStage) {
        Integer priorOrdinal = ordinalOf(priorStage);
        Integer nextOrdinal = ordinalOf(nextStage);
        if (priorOrdinal == null || nextOrdinal == null) {
            return false;
        }
        return nextOrdinal > priorOrdinal;
    }

    /**
     * The display coordinate of a checklist item - its parent group letter plus its sequence.
     *
     * THIS MATCHES `ChecklistMigrationDomain.coordinateOf` BYTE FOR BYTE, ON PURPOSE. The
     * coordinate is how every part of this feature family names an item without ever using
     * Subject text as a key - the migration audit prints it, `ChecklistCaptureDefProvider` keys
     * on it, and the fan-out resolves prerequisites by it. A second format for the same concept
     * in the same feature is how two things that must agree stop agreeing.
     *
     * It is NOT implemented by calling `ChecklistMigrationDomain`, deliberately: that whole class
     * is scheduled for deletion at M5 with the rest of the Task-model stack, and a live safety
     * gate must not acquire a dependency on code that is being retired.
     *
     * DIVERGENCE FROM THE DESIGN DOCUMENT, FLAGGED RATHER THAN SILENTLY RESOLVED. Design B2.5
     * illustrates the coordinate as `A4`, `H2:5` while ALSO stating it is "the same coordinate the
     * M2 audit and the fan-out prerequisite index use". Those two statements disagree: the audit
     * produces `H25` for group `H2` sequence 5, not `H2:5`. The RULE was followed over the
     * EXAMPLE. In practice there is no collision - group `H2` holds 5 items and group `H` holds 5,
     * so `H25` cannot also be H item 25 - but it does read oddly, and changing to a separated form
     * is a one-line change here IF the user prefers it. It must then change in
     * `ChecklistMigrationDomain` in the same edit, or the two formats diverge.
     *
     * @param groupLetter The parent `Checklist__c.Group_Letter__c` (`A` through `J`, plus `H2`);
     *                    null- and blank-safe.
     * @param sequence    The item `Sequence__c`. A Number field, so it arrives as `Decimal`;
     *                    truncated with `intValue()` because the field is scale 0. Null-safe.
     * @return e.g. `A4`, `B2`, `H25`; NULL when either part is absent, which the caller must
     *         handle rather than print.
     * @example
     * String coordinate = TransactionStageDomain.coordinateOf(item.Checklist__r.Group_Letter__c, item.Sequence__c);
     */
    public static String coordinateOf(String groupLetter, Decimal sequence) {
        if (String.isBlank(groupLetter) || sequence == null) {
            return null;
        }
        return groupLetter.toUpperCase() + String.valueOf(sequence.intValue());
    }

    /**
     * Builds the ordinal index from `ORDER`. Called once, from the static initialiser.
     *
     * @return Stage value to zero-based position.
     */
    private static Map<String, Integer> buildOrdinals() {
        Map<String, Integer> ordinals = new Map<String, Integer>();
        for (Integer i = 0; i < ORDER.size(); i++) {
            ordinals.put(ORDER[i], i);
        }
        return ordinals;
    }
}
