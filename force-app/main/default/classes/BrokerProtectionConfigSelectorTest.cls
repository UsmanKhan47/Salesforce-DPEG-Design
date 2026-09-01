/**
 * Tests for `BrokerProtectionConfigSelector` — the one SOQL read of
 * `Broker_Protection_Config__mdt.Extraction_Prompt__c`, added 2026-08-31 as the root-cause half
 * of a live P0 (`getInstance()` clips LongTextArea to 255 characters; SOQL does not).
 *
 * ═══ 🔴 NO 251-RECORD BULK TEST — EXEMPT, AND THE REASONING IS RECORDED SO REVIEW DOES NOT
 *     DEMAND ONE LATER ═══
 * `.claude/rules/bulk-test-rule.md` mandates 251 records for triggers, batches, queueables and
 * DML-performing services, and carves out per-transaction-singleton paths. This selector is in
 * the carve-out on three independent grounds, any one of which is sufficient:
 *   1. **It is a single-record read by `DeveloperName`.** No trigger, no batch, no loop — there
 *      is no second 200-record batch chunk to force, so 251 rows would exercise exactly zero
 *      additional lines of the method.
 *   2. **A test CANNOT insert `__mdt` rows by DML at all.** Custom Metadata records are
 *      metadata, not data; `insert new Broker_Protection_Config__mdt(...)` does not compile as a
 *      DML target here. 251 rows is not merely pointless, it is impossible to construct.
 *   3. **The caller caches.** `BrokerProtectionConfig.extractionPromptOverride()` holds the
 *      `promptLoaded` / `cachedPrompt` pair, so this query runs at most once per transaction
 *      however many properties an inbound email carries — which is what
 *      `queryCount_isExactlyOnePerCall` below pins.
 * The rule's other half — no SOQL/DML inside loops — is untouched and still holds.
 *
 * ═══ ⚠ WHAT THIS CLASS CAN AND CANNOT PROVE, STATED UP FRONT ═══
 * Because `__mdt` rows cannot be created by a test, every assertion here about the CONTENT of
 * the `Default` record is necessarily conditional on that record existing and being populated —
 * and as of 2026-08-31 the org's `Extraction_Prompt__c` is deliberately BLANK (a zero-code
 * unblock applied in Setup while this fix was being built). `defaultRecord_whenPopulated_isNotTruncated`
 * therefore passes VACUOUSLY in that state, and says so at its own declaration rather than
 * pretending otherwise — AND skips loudly at runtime (`System.debug(LoggingLevel.WARN, ...)`
 * on both the absent and the blank branch), so the skip is visible in a debug log, not only to
 * whoever reads the source next.
 *
 * 🔴 THE NON-VACUOUS GUARDS FOR THE P0 LIVE IN `LLMExtractionCalloutServiceTest` (T1-T4). Those
 * drive everything through `BrokerProtectionConfig.overrideForTest(...)`, so they are org-state
 * INDEPENDENT and cannot go quiet when a record is blank. Do not read this class as the
 * regression net; it is the selector's own contract test.
 *
 * @see BrokerProtectionConfigSelector.cls
 * @see LLMExtractionCalloutServiceTest.cls (T1-T4 — the org-state-independent regression net)
 */
@isTest
private class BrokerProtectionConfigSelectorTest {

    /** A DeveloperName no loader writes and no admin would type. */
    private static final String ABSENT_NAME = 'ZZ_No_Such_Config_Record_ZZ';

    /**
     * A blank or null name must return null WITHOUT spending a query.
     *
     * The query-count half is the point. The guard is a Return-Early check whose only visible
     * effect is the query it does not issue; an assertion on the null alone would still pass if
     * someone deleted the guard, because the query would also return no rows.
     */
    @isTest
    static void blankName_returnsNullWithoutSpendingAQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        Broker_Protection_Config__mdt fromNull = BrokerProtectionConfigSelector.selectByDeveloperName(null);
        Broker_Protection_Config__mdt fromEmpty = BrokerProtectionConfigSelector.selectByDeveloperName('');
        Broker_Protection_Config__mdt fromSpaces = BrokerProtectionConfigSelector.selectByDeveloperName('   ');
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.isNull(fromNull, 'A null DeveloperName must return null');
        Assert.isNull(fromEmpty, 'An empty DeveloperName must return null');
        Assert.isNull(fromSpaces, 'A whitespace-only DeveloperName must return null');
        Assert.areEqual(0, spent,
            'The blank guard must RETURN EARLY, not fall through to a query that happens to match '
            + 'nothing — this selector sits on ExtractAddressQueueable`s pinned QUERY_BUDGET path');
    }

    /**
     * A name that matches no row must return NULL, not an empty row.
     *
     * 🔴 THIS IS A CONTRACT, NOT AN IMPLEMENTATION DETAIL. It matches `getInstance()`'s measured
     * behaviour (`usman-dpeg`, 2026-08-30: `getInstance('<missing>')` returns null), which is
     * what `BrokerProtectionConfig`'s every-accessor-defaults design is built on. "Record absent"
     * is REACHABLE in every freshly built org, because the `Default` record is created by
     * `scripts/load-broker-protection-config.apex` and not by a deploy. If this ever started
     * returning an empty row instead, `extractionPromptOverride()` would return a blank string's
     * worth of nothing and the shipped-prompt fallback would still fire — but every future
     * caller reading a different field would get a silent null instead of a clean absence.
     */
    @isTest
    static void unknownName_returnsNullNotAnEmptyRow() {
        Test.startTest();
        Broker_Protection_Config__mdt row = BrokerProtectionConfigSelector.selectByDeveloperName(ABSENT_NAME);
        Test.stopTest();

        Assert.isNull(row, 'A DeveloperName matching no row must return null, never an empty sObject');
    }

    /**
     * One call costs exactly one SOQL.
     *
     * This is the number `BrokerProtectionConfigSelector`'s header and
     * `BrokerProtectionConfig`'s rewritten LAYER block both claim, and it is the number
     * `ExtractAddressQueueableTest`'s QUERY_BUDGET ceilings (120 at N=10, 60 for the CFO path,
     * against an async cap of 200) have to absorb. If a future edit adds a describe call, a
     * second query, or a retry loop here, this fails BEFORE the budget test does — and with a
     * message that says where to look.
     */
    @isTest
    static void queryCount_isExactlyOnePerCall() {
        Test.startTest();
        Integer before = Limits.getQueries();
        BrokerProtectionConfigSelector.selectByDeveloperName(ABSENT_NAME);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(1, spent,
            'One selector call must cost exactly one SOQL. The caller caches on top of this, so '
            + 'the extraction transaction pays +1 in total, not +1 per property');
    }

    /**
     * The `Default` record, read the way production reads it.
     *
     * ⚠ ORG-STATE DEPENDENT AND DELIBERATELY CONDITIONAL — READ THIS BEFORE "FIXING" IT.
     * A test cannot create a `__mdt` row, so this cannot assert that the record exists. Three
     * states are all legitimate and all must pass:
     *   • **absent** — a freshly built org before `scripts/load-broker-protection-config.apex`
     *     has been run;
     *   • **present, prompt blank** — the org's state on 2026-08-31, a deliberate Setup unblock;
     *   • **present, prompt populated** — a loaded org, the intended steady state.
     *
     * 🔴 IN THE FIRST TWO STATES THE TRUNCATION ASSERTION IS VACUOUS. That is named here rather
     * than hidden, and it is why it is not the regression net: `LLMExtractionCalloutServiceTest`
     * T1-T4 carry that load through `overrideForTest(...)` and cannot go quiet. What this test
     * DOES prove unconditionally is that the query compiles, runs, and returns at most one row
     * for `DeveloperName = 'Default'` — i.e. that the selector is wired to the record the
     * config class asks for.
     *
     * In the THIRD state it becomes the only assertion in the repo that catches a re-truncation
     * against the live org: a value that comes back at exactly 255 characters is the accessor
     * bug returning, and 255 is not a length any real extraction prompt has.
     */
    @isTest
    static void defaultRecord_whenPopulated_isNotTruncated() {
        Test.startTest();
        Broker_Protection_Config__mdt row =
            BrokerProtectionConfigSelector.selectByDeveloperName(BrokerProtectionConfig.RECORD_NAME);
        Test.stopTest();

        if (row == null) {
            // Fresh org, loader not yet run. Nothing to assert about content; the query ran.
            // SKIP LOUDLY rather than silently — this is a live-org observation test, not an
            // injectable one (a __mdt row cannot be created by DML in a test), so "record
            // absent" cannot be turned into a real assertion here. It IS turned into a runtime
            // signal so the skip is visible in a debug log, not only to a source reader.
            System.debug(LoggingLevel.WARN,
                'defaultRecord_whenPopulated_isNotTruncated SKIPPED (vacuous): '
                + 'Broker_Protection_Config__mdt.' + BrokerProtectionConfig.RECORD_NAME
                + ' does not exist in this org. This test cannot create one (CMDT rows are not '
                + 'DML-insertable in tests); the non-vacuous truncation regression net is '
                + 'LLMExtractionCalloutServiceTest T1-T4, which are org-state independent.');
            return;
        }

        Assert.areEqual(BrokerProtectionConfig.RECORD_NAME, row.DeveloperName,
            'The selector must return the record it was asked for, not an arbitrary row');

        if (String.isBlank(row.Extraction_Prompt__c)) {
            // Blank is a SUPPORTED state — an admin who clears the field in Setup gets the
            // shipped prompt back. LLMExtractionCalloutServiceTest T3 pins that contract.
            // SKIP LOUDLY — see the null-row branch above for why this cannot be an assertion.
            System.debug(LoggingLevel.WARN,
                'defaultRecord_whenPopulated_isNotTruncated SKIPPED (vacuous): '
                + 'Broker_Protection_Config__mdt.' + BrokerProtectionConfig.RECORD_NAME
                + '.Extraction_Prompt__c is blank in this org (a deliberate Setup unblock as of '
                + '2026-08-31). The truncation assertion below cannot run against a blank value; '
                + 'the non-vacuous regression net is LLMExtractionCalloutServiceTest T1-T4.');
            return;
        }

        Assert.isTrue(row.Extraction_Prompt__c.length() > 255,
            'A populated Extraction_Prompt__c read by SOQL must exceed 255 characters. Exactly '
            + '255 is the signature of the getInstance()/getAll() truncation this selector exists '
            + 'to bypass (measured usman-dpeg 2026-08-31: getInstance 255 / SOQL 20,596). Got: '
            + row.Extraction_Prompt__c.length());
    }
}
