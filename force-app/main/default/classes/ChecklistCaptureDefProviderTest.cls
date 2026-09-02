/**
 * Tests for `ChecklistCaptureDefProvider` — the Phase 5 item-to-output map.
 *
 * ── NO BULK VOLUME TEST HERE, AND THAT IS CORRECT RATHER THAN AN OMISSION ──────────────────
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies to triggers, batch jobs,
 * DML-performing services and queueables — things whose behaviour changes with row count. This
 * class under test performs ZERO SOQL and ZERO DML and holds no collection whose size comes from
 * data: it is a compile-time constant map behind three pure lookups. A 251-iteration loop over
 * `forCoordinate` would exercise the same single line 251 times and prove nothing the single call
 * does not. The bulk proof for this feature lives where the DML does — `LoanServiceTest`,
 * `InsuranceBinderServiceTest` and `ChecklistOutcomeServiceTest`.
 *
 * ── THE HIGHEST-VALUE TEST IN THIS CLASS IS `everyNamedFieldExistsOnItsTargetObject` ───────
 * The map's failure mode is a TYPO, not a logic error: a `captureFields` entry naming a field that
 * does not exist compiles fine (it is a String), reaches production, and then blows up inside a
 * `lightning-record-edit-form` at the moment a user opens a dialog. That test resolves every named
 * field against the live describe, so a rename or a mistyped API name fails HERE.
 */
@isTest
private class ChecklistCaptureDefProviderTest {

    @isTest
    static void forCoordinateResolvesEveryDocumentedCoordinate() {
        // The 12 coordinates the feature claims to cover, asserted BY NAME so that deleting one
        // from the map fails here rather than silently disabling that item's capture.
        Map<String, ChecklistCaptureDefProvider.CaptureMode> expected =
            new Map<String, ChecklistCaptureDefProvider.CaptureMode>{
                'A|5'  => ChecklistCaptureDefProvider.CaptureMode.DERIVED,
                'B|5'  => ChecklistCaptureDefProvider.CaptureMode.DERIVED,
                'C|7'  => ChecklistCaptureDefProvider.CaptureMode.DOCUMENT,
                'F|5'  => ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS,
                'F|6'  => ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS,
                'F|9'  => ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS,
                'F|11' => ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS,
                'F|12' => ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS,
                'G|2'  => ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS,
                'G|5'  => ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS,
                'G|6'  => ChecklistCaptureDefProvider.CaptureMode.DOCUMENT,
                'J|4'  => ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS
            };

        for (String key : expected.keySet()) {
            List<String> parts = key.split('\\|');
            ChecklistCaptureDefProvider.CaptureDef def =
                ChecklistCaptureDefProvider.forCoordinate(parts[0], Decimal.valueOf(parts[1]));
            Assert.isNotNull(def, 'Coordinate ' + key + ' must resolve to a capture definition');
            Assert.areEqual(expected.get(key), def.captureMode,
                'Coordinate ' + key + ' must carry the documented capture mode');
        }
        Assert.areEqual(expected.size(), ChecklistCaptureDefProvider.all().size(),
            'The map must contain EXACTLY the documented coordinates and no others — an extra '
                + 'entry silently starts gating an item nobody agreed to gate');
    }

    @isTest
    static void loanAndBinderCoordinatesPointAtTheRightObject() {
        for (String key : new List<String>{ 'F|5', 'F|6', 'F|9', 'F|11', 'F|12', 'J|4' }) {
            Assert.areEqual(
                ChecklistCaptureDefProvider.TARGET_LOAN,
                defFor(key).targetObject,
                key + ' is a financing step and must write to Loan__c'
            );
        }
        for (String key : new List<String>{ 'G|2', 'G|5' }) {
            Assert.areEqual(
                ChecklistCaptureDefProvider.TARGET_BINDER,
                defFor(key).targetObject,
                key + ' is an insurance step and must write to Insurance_Binder__c'
            );
        }
    }

    @isTest
    static void theSevenNamedLoanDataPointsAreAllCapturedSomewhere() {
        // The Phase 5 brief names seven things to capture: lender, amount, term, rate, bank account
        // type, auto-payment status, commitment date. This asserts the UNION of the F/J capture
        // fields covers all seven — so dropping a coordinate that was the only home for one of them
        // fails here with a message naming the lost field, rather than being noticed in production.
        Set<String> captured = new Set<String>();
        for (ChecklistCaptureDefProvider.CaptureDef def : ChecklistCaptureDefProvider.all().values()) {
            if (ChecklistCaptureDefProvider.TARGET_LOAN.equals(def.targetObject)) {
                captured.addAll(def.captureFields);
            }
        }
        for (String field : new List<String>{
            'Lender_Name__c', 'Loan_Amount__c', 'Term_Months__c', 'Interest_Rate_Pct__c',
            'Bank_Account_Type__c', 'Auto_Payment_Status__c', 'Commitment_Date__c'
        }) {
            Assert.isTrue(captured.contains(field),
                'No checklist coordinate captures Loan__c.' + field + ' — that data point has no '
                    + 'home and the field is an empty shell again');
        }
    }

    @isTest
    static void theFiveNamedBinderDataPointsAreAllCapturedSomewhere() {
        Set<String> captured = new Set<String>();
        for (ChecklistCaptureDefProvider.CaptureDef def : ChecklistCaptureDefProvider.all().values()) {
            if (ChecklistCaptureDefProvider.TARGET_BINDER.equals(def.targetObject)) {
                captured.addAll(def.captureFields);
            }
        }
        for (String field : new List<String>{
            'Carrier_Name__c', 'Policy_Number__c', 'Coverage_Amount__c',
            'Binding_Deadline_Date__c', 'Bound_Date__c'
        }) {
            Assert.isTrue(captured.contains(field),
                'No checklist coordinate captures Insurance_Binder__c.' + field);
        }
        Assert.isFalse(captured.contains('Is_Bound__c'),
            'Is_Bound__c is a FORMULA over Bound_Date__c. Offering it in a capture form puts a '
                + 'non-writable field in a lightning-record-edit-form and the save fails');
    }

    @isTest
    static void autoPaymentCoordinatesAcceptOnlyActive() {
        // 🔴 WITHOUT THIS NARROWING THE F12/J4 GUARD IS VACUOUS. `Auto_Payment_Status__c` carries
        // `<default>true</default>` on `Not Set Up`, so the platform stamps a non-blank value the
        // moment `LoanService.ensureFor` inserts the row - and F5, F6, F9, F11 and F12 all share
        // one `Loan__c`. Asserting the SET by value, not merely that one exists, so a later edit
        // that re-admits `Requested` or `Failed` fails here with a message naming what changed.
        for (String key : new List<String>{ 'F|12', 'J|4' }) {
            ChecklistCaptureDefProvider.CaptureDef def = defFor(key);
            Assert.isNotNull(def.satisfyingValues,
                key + ' writes a picklist with a DEFAULT and must narrow which values count');
            Assert.areEqual(new Set<String>{ 'Active' }, def.satisfyingValues,
                key + ' must accept ONLY Active: Not Set Up is the platform default, Requested is '
                    + 'a mandate asked for rather than running, and Failed is a recorded outcome '
                    + 'rather than a completed setup');
        }
    }

    @isTest
    static void noOtherCoordinateNarrowsItsAcceptedValues() {
        // The converse control. Narrowing a field that has no default would refuse correct answers
        // - `Bank_Account_Type__c` has zero defaults, so every declared value is a real selection,
        // and Text / Currency / Date coordinates have no enumerable value set at all.
        for (String key : ChecklistCaptureDefProvider.all().keySet()) {
            if (key == 'F|12' || key == 'J|4') {
                continue;
            }
            Assert.isNull(ChecklistCaptureDefProvider.all().get(key).satisfyingValues,
                key + ' must accept any non-blank value; narrowing it would refuse real answers');
        }
    }

    @isTest
    static void everyNarrowedValueIsRealOnTheTargetPicklist() {
        // A narrowing that names a value the picklist does not have refuses EVERYTHING, silently
        // and forever. Resolved against the live describe so a picklist rename fails here.
        Set<String> declared = new Set<String>();
        for (Schema.PicklistEntry entry
                : Loan__c.Auto_Payment_Status__c.getDescribe().getPicklistValues()) {
            declared.add(entry.getValue());
        }
        Integer checked = 0;
        for (String key : new List<String>{ 'F|12', 'J|4' }) {
            for (String value : defFor(key).satisfyingValues) {
                Assert.isTrue(declared.contains(value),
                    key + ' accepts "' + value + '", which is not a value of '
                        + 'Loan__c.Auto_Payment_Status__c - the guard would refuse every state');
                checked++;
            }
        }
        Assert.areEqual(2, checked, 'Both narrowed coordinates were checked, not zero of them');
    }

    @isTest
    static void everyNamedFieldExistsOnItsTargetObject() {
        // 🔴 THE TYPO CATCHER. Field API names in this map are Strings, so a rename or a mistyped
        // name compiles, deploys, and only fails when a user opens the dialog. Resolving each one
        // against the live describe moves that failure to here.
        Map<String, Map<String, Schema.SObjectField>> fieldsByObject =
            new Map<String, Map<String, Schema.SObjectField>>{
                ChecklistCaptureDefProvider.TARGET_LOAN =>
                    Loan__c.SObjectType.getDescribe().fields.getMap(),
                ChecklistCaptureDefProvider.TARGET_BINDER =>
                    Insurance_Binder__c.SObjectType.getDescribe().fields.getMap()
            };

        Integer checkedFields = 0;
        for (String key : ChecklistCaptureDefProvider.all().keySet()) {
            ChecklistCaptureDefProvider.CaptureDef def = ChecklistCaptureDefProvider.all().get(key);
            if (def.targetObject == null) {
                continue;
            }
            Map<String, Schema.SObjectField> fields = fieldsByObject.get(def.targetObject);
            Assert.isNotNull(fields, key + ' names an object with no describe: ' + def.targetObject);
            for (String apiName : def.captureFields) {
                Assert.isTrue(fields.containsKey(apiName.toLowerCase()),
                    key + ' names ' + def.targetObject + '.' + apiName + ', which does not exist');
                checkedFields++;
            }
            if (def.requiredField != null) {
                Assert.isTrue(fields.containsKey(def.requiredField.toLowerCase()),
                    key + ' requires ' + def.targetObject + '.' + def.requiredField
                        + ', which does not exist');
            }
        }
        // The control. Without it a map that somehow produced no field names at all would pass this
        // test vacuously, which is exactly the failure it exists to catch.
        Assert.isTrue(checkedFields >= 12,
            'Expected at least 12 field names to check across the loan and binder coordinates, '
                + 'checked ' + checkedFields + ' — the loop found nothing to verify');
    }

    @isTest
    static void everyRequiredFieldIsAlsoOfferedInTheDialog() {
        // A requirement the dialog does not render is a requirement the user cannot satisfy — the
        // completion would be refused forever with no way to fix it from the screen.
        for (String key : ChecklistCaptureDefProvider.all().keySet()) {
            ChecklistCaptureDefProvider.CaptureDef def = ChecklistCaptureDefProvider.all().get(key);
            if (def.requiredField == null
                    || def.captureMode != ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS) {
                continue;
            }
            Assert.isTrue(def.captureFields.contains(def.requiredField),
                key + ' requires ' + def.requiredField
                    + ' but does not offer it in the dialog — unsatisfiable by construction');
        }
    }

    @isTest
    static void everyRefusalMessageIsPresentAndAscii() {
        // ⚠ `SObject.addError` HTML-ESCAPES its message and this repo has already been bitten by an
        // em-dash rendering as an entity. These strings also travel through AuraHandledException to
        // a toast. Plain ASCII, and never empty — a blank refusal tells the user nothing.
        for (String key : ChecklistCaptureDefProvider.all().keySet()) {
            ChecklistCaptureDefProvider.CaptureDef def = ChecklistCaptureDefProvider.all().get(key);
            // A coordinate can refuse a completion when it is a DOCUMENT capture (a file is always
            // required) or a TARGET_FIELDS capture with a required field. Everything else — DERIVED,
            // and the optional F11 — has nothing to explain. Written as an explicit predicate
            // rather than a compound negation so the precedence is not something to work out.
            Boolean canRefuse =
                def.captureMode == ChecklistCaptureDefProvider.CaptureMode.DOCUMENT
                || (def.captureMode == ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS
                    && def.requiredField != null);
            if (!canRefuse) {
                continue;
            }
            Assert.isTrue(String.isNotBlank(def.requirementMessage),
                key + ' can refuse a completion but carries no explanation');
            Assert.isTrue(
                Pattern.matches('[\\x20-\\x7E]+', def.requirementMessage),
                key + ' refusal message contains a non-ASCII character: ' + def.requirementMessage
            );
        }
    }

    @isTest
    static void derivedCoordinatesCarryAnOutcomeAndNothingElse() {
        ChecklistCaptureDefProvider.CaptureDef a5 = defFor('A|5');
        Assert.areEqual(ChecklistCaptureDefProvider.DerivedOutcome.CRITICAL_DATES, a5.derivedOutcome,
            'A5 logs the critical dates');
        Assert.isNull(a5.targetObject, 'A DERIVED coordinate writes the deal, not a related object');
        Assert.isTrue(a5.captureFields.isEmpty(), 'A DERIVED coordinate asks the user for nothing');

        ChecklistCaptureDefProvider.CaptureDef b5 = defFor('B|5');
        Assert.areEqual(
            ChecklistCaptureDefProvider.DerivedOutcome.EARNEST_MONEY_SENT, b5.derivedOutcome,
            'B5 stamps Earnest Money Sent'
        );
    }

    @isTest
    static void unmappedAndMalformedCoordinatesResolveToNull() {
        // Null is the NORMAL answer — 64 of the 82 items record nothing — so it must never throw.
        Assert.isNull(ChecklistCaptureDefProvider.forCoordinate('D', 1),
            'Group D carries no capture coordinate');
        Assert.isNull(ChecklistCaptureDefProvider.forCoordinate('F', 7),
            'F7 forms the deal entity and has no Loan__c field behind it — deliberately unmapped');
        Assert.isNull(ChecklistCaptureDefProvider.forCoordinate('F', 8),
            'F8 opens the bank account; F9 records its TYPE. F8 itself is unmapped');
        Assert.isNull(ChecklistCaptureDefProvider.forCoordinate('F', 10),
            'F10 obtains wiring instructions, which live on Wire__c and are out of Phase 5 scope');
        Assert.isNull(ChecklistCaptureDefProvider.forCoordinate(null, 5), 'Null letter is safe');
        Assert.isNull(ChecklistCaptureDefProvider.forCoordinate('F', null), 'Null sequence is safe');
        Assert.isNull(ChecklistCaptureDefProvider.forCoordinate('', 5), 'Blank letter is safe');
    }

    @isTest
    static void lookupIsCaseInsensitiveOnTheGroupLetter() {
        // ⚠ Apex Map<String, ...> lookups ARE case-sensitive even though String `==` is not, so the
        // normalisation inside `coordinateKey` is load-bearing rather than defensive.
        Assert.isNotNull(ChecklistCaptureDefProvider.forCoordinate('f', 9),
            'A lower-case group letter must still resolve');
        Assert.areEqual('F|9', ChecklistCaptureDefProvider.coordinateKey('f', 9),
            'coordinateKey normalises to upper case');
    }

    @isTest
    static void fractionalSequenceTruncatesRatherThanMissing() {
        // `Sequence__c` is a Decimal on the sObject even though it is scale 0 on the field, so a
        // value arriving as 9.0 must resolve exactly as 9 does.
        Assert.isNotNull(ChecklistCaptureDefProvider.forCoordinate('F', 9.0),
            'A Decimal sequence of 9.0 is coordinate F|9');
    }

    /**
     * The loader's subject at each capture coordinate, copied by hand from
     * `scripts/load-transaction-task-defs.apex` (lines 10, 17, 25, 44, 45, 48, 50, 51, 54, 57, 58,
     * 86 as of 2026-09-02).
     *
     * 🔴 A HAND-MAINTAINED MIRROR, AND IT HAS TO BE. `scripts/*.apex` is not readable from Apex, so
     * nothing can diff the two automatically. Editing the loader means editing this constant in the
     * same change - that obligation is the point of the constant existing.
     */
    private static final Map<String, String> LOADER_SUBJECT_BY_COORDINATE =
        new Map<String, String>{
            'A|5'  => 'Log critical dates into Salesforce deal record',
            'B|5'  => 'Update deal record: Earnest Money Sent = Yes',
            'C|7'  => 'Upload PCR to deal document folder',
            'F|5'  => 'Review term sheets with CFO - select preferred lender',
            'F|6'  => 'Sign selected term sheet',
            'F|9'  => 'Select bank account type',
            'F|11' => 'Send executed company agreement to lender bank',
            'F|12' => 'Set up auto loan payment (CRITICAL - frequently missed)',
            'G|2'  => 'Provide broker estimated loan amount, coverage, binding deadline',
            'G|5'  => 'Select and bind insurance policy',
            'G|6'  => 'Upload insurance documents to deal folder',
            'J|4'  => 'Set up auto loan payment at lender bank (CRITICAL)'
        };

    @isTest
    static void everyCoordinateStillMatchesItsLoaderSubject() {
        // 🔴 THE RENUMBER TRIPWIRE. The map keys on `(group letter, sequence)`, so renumbering a
        // group in the loader silently re-points every capture - F9 would stop meaning "Select bank
        // account type" and start meaning whatever landed at 9, with a green deploy and a green
        // suite. This is the only thing standing in front of that.

        // HALF ONE — always runs, never vacuous. The mirror must cover exactly the map.
        Assert.areEqual(
            ChecklistCaptureDefProvider.all().size(),
            LOADER_SUBJECT_BY_COORDINATE.size(),
            'The loader mirror and the capture map must describe the same number of coordinates'
        );
        for (String key : ChecklistCaptureDefProvider.all().keySet()) {
            Assert.isTrue(LOADER_SUBJECT_BY_COORDINATE.containsKey(key),
                'Coordinate ' + key + ' is in the capture map but not in the loader mirror. Adding '
                    + 'a coordinate means confirming what the loader actually has there');
        }

        // HALF TWO — org-state-dependent, and reported so a vacuous pass is visible.
        Map<String, String> orgSubjectByCoordinate = new Map<String, String>();
        for (Transaction_Task_Def__mdt def
                : TransactionTaskDefProvider.getAllOrderedByGroupAndSequence()) {
            if (def.Group_Letter__c == null || def.Sequence__c == null) {
                continue;
            }
            orgSubjectByCoordinate.put(
                ChecklistCaptureDefProvider.coordinateKey(
                    def.Group_Letter__c, def.Sequence__c.intValue()),
                def.Subject__c
            );
        }

        Integer verified = 0;
        for (String key : LOADER_SUBJECT_BY_COORDINATE.keySet()) {
            String orgSubject = orgSubjectByCoordinate.get(key);
            if (orgSubject == null) {
                continue;
            }
            Assert.areEqual(LOADER_SUBJECT_BY_COORDINATE.get(key), orgSubject,
                'Coordinate ' + key + ' has MOVED. The capture map still points at it but the '
                    + 'definition there is now a different step, so that step captures the wrong '
                    + 'thing and the intended one captures nothing. Re-check the loader.');
            verified++;
        }

        // ⚠ NOT AN ASSERTION ON `verified`, DELIBERATELY. CMDT records are force-ignored and loaded
        // by a script, so an org where that script has never run legitimately has zero rows and
        // failing here would red-line every fresh scratch org. The count is asserted only to be
        // ALL-OR-NOTHING: either the definitions are loaded and all twelve are checked, or none is.
        // A partial number means the loader ran against a different coordinate set, which is
        // exactly the drift this test is for.
        Assert.isTrue(verified == 0 || verified == LOADER_SUBJECT_BY_COORDINATE.size(),
            'Expected either 0 loaded definitions (loader never run in this org) or all '
                + LOADER_SUBJECT_BY_COORDINATE.size() + ', but ' + verified + ' of the capture '
                + 'coordinates resolved. A partial match means the loaded definitions no longer '
                + 'carry the coordinates this map is keyed on.');
    }

    private static ChecklistCaptureDefProvider.CaptureDef defFor(String key) {
        List<String> parts = key.split('\\|');
        ChecklistCaptureDefProvider.CaptureDef def =
            ChecklistCaptureDefProvider.forCoordinate(parts[0], Decimal.valueOf(parts[1]));
        Assert.isNotNull(def, 'Coordinate ' + key + ' must resolve');
        return def;
    }
}
