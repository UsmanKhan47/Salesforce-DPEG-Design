/**
 * The Phase 5 item-to-output map: which checklist coordinates record something, where that
 * something goes, and what must be on file before the item is allowed to close.
 *
 * layer=provider (the same layer as `TaskGroupDefProvider` / `TransactionTaskDefProvider`). ZERO
 * SOQL, ZERO DML, ZERO describe calls - every method is a pure function over compile-time
 * constants. Nothing here touches the database, so it can be called from any context at any
 * record count for free.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE KEY IS THE COORDINATE `(group letter, sequence)`. IT IS NEVER THE SUBJECT TEXT.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Design §5.7 is explicit: "keyed on the `Checklist_Item__c` record, resolved via `Sequence__c` +
 * parent `Group_Letter__c` - NEVER on subject text". That is not a style preference. The whole
 * Phase 2/3 rewrite exists to retire exactly one pattern - RISK 1, the
 * `Subject.toLowerCase().contains('anti-fraud')` parse that reads zero the moment a subject is
 * edited and throws nothing when it does. A `switch on subject` here would re-import that failure
 * into a new file: an admin retitling "Select bank account type" would silently stop the loan
 * capture, with a green deploy and a passing test suite.
 *
 * ⚠ THE COORDINATE IS NOT FREE OF RISK. Renumbering a group in
 * `scripts/load-transaction-task-defs.apex` re-points every entry below, silently. THE MITIGATION
 * IS PARTIAL AND ITS LIMITS ARE STATED HERE RATHER THAN IMPLIED:
 *   ✅ `ChecklistCaptureDefProviderTest.everyCoordinateStillMatchesItsLoaderSubject` mirrors the
 *      loader's twelve (coordinate -> subject) pairs as a test constant, asserts that mirror covers
 *      EXACTLY the coordinates in this map, and then checks each one against the
 *      `Transaction_Task_Def__mdt` rows the org actually holds. A renumber that moves `F9` off
 *      "Select bank account type" fails there.
 *   ⚠ THE SUBJECT HALF IS ORG-STATE-DEPENDENT. CMDT *records* are force-ignored and loaded by that
 *      script, so in an org where the loader has never run there are no rows to compare against and
 *      only the mirror-completeness half of the test does any work. It reports how many coordinates
 *      it actually verified so a vacuous pass is visible rather than silent.
 *   ❌ NOTHING READS THE SCRIPT ITSELF. `scripts/*.apex` is not readable from Apex, so the mirror is
 *      a HAND-MAINTAINED COPY. Editing the loader means editing that constant in the same change.
 * 🔴 AN EARLIER VERSION OF THIS PARAGRAPH CLAIMED A TEST THAT "reads the loader script coordinates
 * back". No such test existed and none could. Do not put a fictional mitigation in front of a real
 * risk - it is worse than naming the risk and leaving it open.
 *
 * ── WHY AN APEX CONSTANT AND NOT A CMDT COLUMN ──────────────────────────────────────────────
 * Design §5.9 offers both ("a new `Target_Field__c` column, or a `ChecklistItemDefProvider`
 * constant"). The constant is chosen, for three measured reasons:
 *   1. The customMetadata directory is force-ignored (`.forceignore:16`), so CMDT ROWS never deploy
 *      - they are loaded by `scripts/load-transaction-task-defs.apex`. A CMDT column therefore makes
 *      every change to this map an ORDERED OPERATIONS STEP (deploy the column, re-run the loader)
 *      rather than a code change, and a loader that is not re-run leaves the map silently empty.
 *   2. A CMDT column would carry the field API name as data, which means it can name a field that
 *      does not exist. An Apex constant naming a bad field fails at COMPILE time.
 *   3. `getAll()` / `getInstance()` silently clip LongTextArea and Html to 255 characters
 *      (ARCHITECTURE.md §2; it cost a live P0 on 2026-08-31). Every string here is short, but the
 *      constant sidesteps the question entirely rather than relying on nobody ever widening a
 *      column.
 *
 * ── SCOPE NOTE: F12 AND J4 ARE IN THE MAP, AND THE BRIEF SAID "F5-F11" ─────────────────────
 * Deliberate, and evidenced rather than assumed. The Phase 5 brief scopes the loan capture to
 * "F5-F11" but names `auto-payment status` in the same sentence as the data to capture, and F5-F11
 * contains no auto-payment step. `Loan__c.Auto_Payment_Status__c`'s own field XML settles it: "Backs
 * the two items the business flags as CRITICAL and frequently missed - F12 during closing prep and
 * J4 post-closing at the lender bank." So the field was specified for F12/J4 by the schema pass,
 * and mapping it to F5-F11 instead would leave the org unable to record the ONE loan fact the
 * business flags as most often missed. Both coordinates write the same field on the same
 * `Loan__c`; J4 simply revisits it after closing.
 *
 * ── WHAT IS DELIBERATELY ABSENT ─────────────────────────────────────────────────────────────
 * F7 (form entity), F8 (open bank account) and F10 (obtain wiring instructions) have NO entry.
 * They are real steps with no `Loan__c` field behind them: entity formation is `H2`/legal, and wire
 * instructions live on `Wire__c`, which Phase 5 does not touch. An entry pointing at a field that
 * does not model the step would be worse than no entry - it would make the capture dialog ask for
 * something the item is not about. `Title_Company__c` and `Vendor__c` are absent for the reason the
 * brief gives: they are unspecified by the business and nothing writes to them.
 *
 * @see force-app/main/default/classes/ChecklistCaptureService.cls (resolves a def into a context)
 * @see force-app/main/default/classes/ChecklistOutcomeService.cls (executes the DERIVED defs)
 * @see agent-output/design-transaction-fsd-gaps.md §5.7, §5.8, §5.9
 */
public with sharing class ChecklistCaptureDefProvider {

    /**
     * What kind of output an item records. An enum rather than string constants, per the project
     * Apex rules ("use enums over string constants whenever possible").
     */
    public enum CaptureMode {
        /** The user fills fields on a related record (`Loan__c` / `Insurance_Binder__c`). */
        TARGET_FIELDS,
        /** The user uploads a file, which is linked to the deal and to the item. */
        DOCUMENT,
        /** No user input - the server derives and writes the outcome on completion. */
        DERIVED
    }

    /** Which derived outcome a `DERIVED` item triggers. */
    public enum DerivedOutcome {
        /** A5 - project the deal dates into `Critical_Date__c` rows. */
        CRITICAL_DATES,
        /** B5 - stamp `Earnest_Money_Sent__c` and `Earnest_Money_Sent_Date__c`. */
        EARNEST_MONEY_SENT
    }

    /** `Loan__c` API name, as a constant so a typo fails at compile time in one place. */
    public static final String TARGET_LOAN = 'Loan__c';

    /** `Insurance_Binder__c` API name. */
    public static final String TARGET_BINDER = 'Insurance_Binder__c';

    /**
     * 🔴 THE ONLY `Auto_Payment_Status__c` VALUE THAT CLOSES F12 OR J4. Business decision, settled
     * 2026-09-02 during Phase 5 review.
     *
     * The other three are all excluded for stated reasons, not by omission:
     *   • `Not Set Up` - the platform DEFAULT, and literally the state meaning the step did not
     *     happen. Accepting it made the guard vacuous; see `CaptureDef.satisfyingValues`.
     *   • `Requested` - a mandate asked for is not a mandate running. This is the exact gap the
     *     business calls "frequently missed": somebody requests it and nobody confirms.
     *   • `Failed` - a recorded OUTCOME, not a completed setup. Leaving it unsatisfying means a
     *     bank rejection forces somebody to act rather than letting the item be closed over it.
     */
    @TestVisible
    private static final Set<String> AUTO_PAYMENT_ACTIVE = new Set<String>{ 'Active' };

    /**
     * One coordinate's capture specification. Immutable by convention - every instance is built
     * once inside the static initialiser below and handed out by reference.
     */
    public class CaptureDef {
        /** Parent `Checklist__c.Group_Letter__c`, e.g. `F`, `G`, `H2`. */
        public String groupLetter;
        /** `Checklist_Item__c.Sequence__c` within that group. */
        public Integer sequence;
        /** What kind of output this item records. */
        public CaptureMode captureMode;
        /**
         * `Loan__c` or `Insurance_Binder__c` for `TARGET_FIELDS`; null for the other two modes.
         * `DOCUMENT` and `DERIVED` both write against the deal itself, which needs no name here.
         */
        public String targetObject;
        /** Field API names the capture dialog offers, in display order. Empty for non-field modes. */
        public List<String> captureFields;
        /**
         * The ONE field that must be non-blank before the item may close, or null when the item
         * records something optional.
         *
         * ⚠ ONE, NOT ALL. Requiring every field would refuse a term sheet that genuinely has no
         * stated term, and a checklist that cannot be completed truthfully gets completed
         * untruthfully. The required field is the one whose absence means the STEP did not happen.
         */
        public String requiredField;
        /**
         * 🔴 THE VALUES OF `requiredField` THAT ACTUALLY COUNT AS RECORDED. NULL MEANS "ANY
         * NON-BLANK VALUE COUNTS", WHICH IS THE RIGHT ANSWER FOR TEXT, CURRENCY AND DATE - AND THE
         * WRONG ANSWER FOR A PICKLIST WITH A DEFAULT.
         *
         * ═══════════════════════════════════════════════════════════════════════════════════
         * THE DEFECT THIS EXISTS FOR, WHICH SHIPPED ONCE AND WAS CAUGHT IN REVIEW.
         * ═══════════════════════════════════════════════════════════════════════════════════
         * `Loan__c.Auto_Payment_Status__c` carries `<default>true</default>` on `Not Set Up`
         * (`Auto_Payment_Status__c.field-meta.xml:15-16`). `LoanService.ensureFor` inserts
         * `new Loan__c(Transaction__c = dealId)` with the field unset, so THE PLATFORM STAMPS
         * `Not Set Up` at insert. A plain "is it non-blank?" test therefore returns TRUE on a loan
         * nobody has touched - and because F5, F6, F9, F11 and F12 all provision the SAME `Loan__c`
         * (pinned by `contextForIsIdempotentAcrossTheFourLoanDialogs`), opening ANY group F dialog
         * made F12 and J4 permanently completable with nothing recorded, and made `contextFor`
         * report `satisfied = true` before the user had started.
         * F12 and J4 are the pair the field's own description calls CRITICAL and most frequently
         * missed, so the one coordinate the guard exists to protect was the one it did not.
         *
         * ⚠ `Bank_Account_Type__c` HAS NO DEFAULT (verified: zero `<default>true</default>` in its
         * field XML), which is why F9 was correct all along and its test legitimately asserts
         * `satisfied == false` after provisioning. The divergence between the two was the tell.
         *
         * ── WHY AN ALLOW-LIST AND NOT A DENY-LIST ──────────────────────────────────────────
         * Review framed this as an "unsatisfying values" concept, and a `Set` of values to REJECT
         * would express today's rule identically. The positive form is used because the two fail in
         * opposite directions when the picklist grows: a new value added to
         * `Auto_Payment_Status__c` later (say `Suspended`, or `Cancelled`) is far more likely to be
         * another NOT-DONE state than another done state. A deny-list would silently start
         * accepting it and re-open exactly this hole; an allow-list refuses it until somebody
         * decides, which is the direction a wire-adjacent control should fail in.
         */
        public Set<String> satisfyingValues;
        /** Which server-side outcome to run; only meaningful when `captureMode` is `DERIVED`. */
        public DerivedOutcome derivedOutcome;
        /** User-safe, user-actionable refusal text. ASCII only - no apostrophes, no em-dashes. */
        public String requirementMessage;

        /**
         * Narrows `requiredField` to an explicit set of accepted values. Fluent so the ten
         * coordinates that need no narrowing keep their constructor call untouched.
         *
         * @param values the values that count as recorded; must be non-empty.
         * @return this def, for chaining at the call site.
         */
        private CaptureDef satisfiedOnlyBy(Set<String> values) {
            this.satisfyingValues = values;
            return this;
        }

        private CaptureDef(
            String groupLetter,
            Integer sequence,
            CaptureMode captureMode,
            String targetObject,
            List<String> captureFields,
            String requiredField,
            DerivedOutcome derivedOutcome,
            String requirementMessage
        ) {
            this.groupLetter = groupLetter;
            this.sequence = sequence;
            this.captureMode = captureMode;
            this.targetObject = targetObject;
            this.captureFields = captureFields == null ? new List<String>() : captureFields;
            this.requiredField = requiredField;
            this.derivedOutcome = derivedOutcome;
            this.requirementMessage = requirementMessage;
        }
    }

    /**
     * The map, keyed by `coordinateKey(groupLetter, sequence)`.
     *
     * ⚠ BUILT WITH REPEATED `put` CALLS, NOT ONE BIG COLLECTION LITERAL. A 45-row nested
     * collection-initialiser literal has been measured in this repo to exceed an Apex parser limit
     * and fail to compile with an error naming the DECLARATION rather than the offending row.
     */
    private static final Map<String, CaptureDef> DEFS_BY_KEY = buildDefs();

    /**
     * The capture specification for one coordinate.
     *
     * @param groupLetter Parent `Checklist__c.Group_Letter__c`; null-safe.
     * @param sequence    `Checklist_Item__c.Sequence__c`; null-safe. Decimal because that is what
     *                    the field returns; the fractional part is ignored.
     * @return the def, or NULL when this coordinate records nothing. Null is the normal case -
     *         64 of the 82 items have no entry - and every caller must treat it as "no capture,
     *         complete normally", never as an error.
     * @example
     * ChecklistCaptureDefProvider.CaptureDef def =
     *     ChecklistCaptureDefProvider.forCoordinate('F', 9);
     */
    public static CaptureDef forCoordinate(String groupLetter, Decimal sequence) {
        if (String.isBlank(groupLetter) || sequence == null) {
            return null;
        }
        // ⚠ `.intValue()`, NOT `Integer.valueOf(sequence)`. `Sequence__c` arrives as a Decimal, and
        // `Integer.valueOf` has no Decimal overload — it would bind to `Integer.valueOf(Object)` and
        // can raise a TypeException at runtime. `intValue()` truncates, which is right: the field is
        // scale 0, so 9.0 is coordinate 9.
        return DEFS_BY_KEY.get(coordinateKey(groupLetter, sequence.intValue()));
    }

    /**
     * The whole map, for tests and for the loader-coordinate cross-check.
     *
     * @return an unmodifiable-by-convention view keyed by `coordinateKey`; never null.
     */
    public static Map<String, CaptureDef> all() {
        return DEFS_BY_KEY;
    }

    /**
     * The canonical key. Upper-cased so a lower-case `f` from a hand-edited row still resolves.
     *
     * ⚠ Apex `Map<String, ...>` lookups ARE case-sensitive even though `==` on Strings is not, so
     * normalising here rather than relying on the comparison is load-bearing.
     *
     * @param groupLetter the group letter.
     * @param sequence    the item sequence.
     * @return `F|9`-shaped key.
     */
    public static String coordinateKey(String groupLetter, Integer sequence) {
        return groupLetter.toUpperCase() + '|' + String.valueOf(sequence);
    }

    /** Builds the map. Called once, from the static initialiser. */
    private static Map<String, CaptureDef> buildDefs() {
        Map<String, CaptureDef> defs = new Map<String, CaptureDef>();

        // ── A - Contract Execution and Title Opening ────────────────────────────────────────
        // A5 "Log critical dates into Salesforce deal record". The step IS the projection, so
        // completing it runs the projection rather than asking the user to retype four dates that
        // are already on the deal record.
        put(defs, new CaptureDef(
            'A', 5, CaptureMode.DERIVED, null, null, null,
            DerivedOutcome.CRITICAL_DATES,
            null
        ));

        // ── B - Earnest Money ───────────────────────────────────────────────────────────────
        // B5 "Update deal record: Earnest Money Sent = Yes". The subject names the write.
        put(defs, new CaptureDef(
            'B', 5, CaptureMode.DERIVED, null, null, null,
            DerivedOutcome.EARNEST_MONEY_SENT,
            null
        ));

        // ── C - Property Condition Report ───────────────────────────────────────────────────
        // C7 "Upload PCR to deal document folder".
        put(defs, new CaptureDef(
            'C', 7, CaptureMode.DOCUMENT, null, null, null, null,
            'Attach the Property Condition Report before completing this item. '
                + 'Use Upload Document in this dialog; the file is filed against the deal.'
        ));

        // ── F - Financing (conditional group, exists only when Loan_Required__c is true) ────
        // F5 "Review term sheets with CFO - select preferred lender".
        put(defs, new CaptureDef(
            'F', 5, CaptureMode.TARGET_FIELDS, TARGET_LOAN,
            new List<String>{ 'Lender_Name__c' },
            'Lender_Name__c', null,
            'Record the selected lender before completing this item.'
        ));
        // F6 "Sign selected term sheet" - the term sheet is where principal, term and rate are
        // fixed, so all three are offered together and the principal is the one that is required.
        put(defs, new CaptureDef(
            'F', 6, CaptureMode.TARGET_FIELDS, TARGET_LOAN,
            new List<String>{ 'Loan_Amount__c', 'Term_Months__c', 'Interest_Rate_Pct__c' },
            'Loan_Amount__c', null,
            'Record the loan amount from the signed term sheet before completing this item.'
        ));
        // F9 "Select bank account type" - the subject and the field are the same sentence.
        put(defs, new CaptureDef(
            'F', 9, CaptureMode.TARGET_FIELDS, TARGET_LOAN,
            new List<String>{ 'Bank_Account_Type__c' },
            'Bank_Account_Type__c', null,
            'Select the bank account type before completing this item. '
                + 'Never record an account or routing number anywhere in Salesforce.'
        ));
        // F11 "Send executed company agreement to lender bank" - the last document the lender needs
        // before it issues its commitment, so this is where the commitment date is known.
        put(defs, new CaptureDef(
            'F', 11, CaptureMode.TARGET_FIELDS, TARGET_LOAN,
            new List<String>{ 'Commitment_Date__c' },
            null, null, null
        ));
        // F12 "Set up auto loan payment (CRITICAL - frequently missed)". See the class header for
        // why this sits outside the brief's stated F5-F11 range.
        put(defs, new CaptureDef(
            'F', 12, CaptureMode.TARGET_FIELDS, TARGET_LOAN,
            new List<String>{ 'Auto_Payment_Status__c' },
            'Auto_Payment_Status__c', null,
            'Set Auto Payment Status to Active before completing this item. '
                + 'Not Set Up, Requested and Failed all mean the payment is not actually running, '
                + 'and this is the loan step the business flags as most frequently missed.'
        ).satisfiedOnlyBy(AUTO_PAYMENT_ACTIVE));

        // ── G - Insurance ───────────────────────────────────────────────────────────────────
        // G2 "Provide broker estimated loan amount, coverage, binding deadline".
        put(defs, new CaptureDef(
            'G', 2, CaptureMode.TARGET_FIELDS, TARGET_BINDER,
            new List<String>{ 'Coverage_Amount__c', 'Binding_Deadline_Date__c' },
            'Binding_Deadline_Date__c', null,
            'Record the binding deadline given to the broker before completing this item.'
        ));
        // G5 "Select and bind insurance policy".
        // 🔴 `Is_Bound__c` IS ABSENT AND MUST STAY ABSENT. It is a FORMULA over `Bound_Date__c`
        // (`NOT(ISBLANK(Bound_Date__c))`). Offering it in the capture dialog would put a
        // non-writable field in a `lightning-record-edit-form`, which fails the save; requiring it
        // here would be requiring a value nobody can enter.
        put(defs, new CaptureDef(
            'G', 5, CaptureMode.TARGET_FIELDS, TARGET_BINDER,
            new List<String>{ 'Carrier_Name__c', 'Policy_Number__c', 'Bound_Date__c' },
            'Bound_Date__c', null,
            'Record the date coverage was bound before completing this item. '
                + 'The Is Bound flag is derived from it automatically.'
        ));
        // G6 "Upload insurance documents to deal folder".
        put(defs, new CaptureDef(
            'G', 6, CaptureMode.DOCUMENT, null, null, null, null,
            'Attach the insurance binder or policy document before completing this item. '
                + 'Use Upload Document in this dialog; the file is filed against the deal.'
        ));

        // ── J - Post-Closing ────────────────────────────────────────────────────────────────
        // J4 "Set up auto loan payment at lender bank (CRITICAL)" - the post-closing revisit of
        // F12, writing the same field on the same Loan__c. Named in Auto_Payment_Status__c's XML.
        put(defs, new CaptureDef(
            'J', 4, CaptureMode.TARGET_FIELDS, TARGET_LOAN,
            new List<String>{ 'Auto_Payment_Status__c' },
            'Auto_Payment_Status__c', null,
            'Set Auto Payment Status to Active before completing this item. '
                + 'Confirm at the lender bank that the payment is actually running - Requested and '
                + 'Failed both mean it is not.'
        ).satisfiedOnlyBy(AUTO_PAYMENT_ACTIVE));

        return defs;
    }

    /** Keys and stores one def. Extracted so the coordinate cannot be typed twice per row. */
    private static void put(Map<String, CaptureDef> defs, CaptureDef def) {
        defs.put(coordinateKey(def.groupLetter, def.sequence), def);
    }
}
