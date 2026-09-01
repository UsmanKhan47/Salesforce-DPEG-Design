/**
 * Selector for `Broker_Protection_Config__mdt`. Encapsulates ALL SOQL against that type per
 * ARCHITECTURE.md §2 and `.claude/rules/apex-layering-rule.md` ("All SOQL must live in Selector
 * classes. Nothing else queries that object.").
 *
 * ═══ 🔴 THIS CLASS EXISTS BECAUSE `getInstance()` SILENTLY TRUNCATES LONG TEXT ═══
 * Created 2026-08-31 as the root-cause half of a LIVE P0. `.claude/skills/sf-apex/SKILL.md`
 * says — and until this change said WITHOUT QUALIFICATION — "when querying Custom Metadata
 * Types, do NOT use SOQL, use `getAll()` / `getInstance()`". That rule is correct for every
 * field shape EXCEPT LongTextArea and Html, which the describe-cache accessors clip to **255
 * characters**, with no exception, no log, and a non-blank return value that passes every
 * `String.isBlank()` guard downstream.
 *
 * MEASURED on `usman-dpeg` at API 67.0 on 2026-08-31, with a control so the result could not
 * be an artifact of the reader:
 *
 *   | probe                                                      | result       |
 *   |------------------------------------------------------------|--------------|
 *   | `getInstance('Default').Extraction_Prompt__c`.length()      | **255**      |
 *   | `[SELECT Extraction_Prompt__c FROM ...]` same row, same txn | **20,596**   |
 *   | `identical`                                                 | **false**    |
 *
 * WHAT IT COST. The 255-character head of that prompt does not contain the token `json`, and
 * `LLMExtractionCalloutService` sends `response_format: {"type":"json_object"}` — which OpenAI
 * refuses unless `messages` contains that token. Every inbound broker email came back HTTP 400,
 * `ExtractAddressQueueable.extractOrDegrade` swallowed the `CalloutException` **by design**, and
 * the pipeline reported SUCCESS while extracting nothing at all. No error, no bounce, no failed
 * job — only `Outcome__c = 'New Lead (no property) — LLM unavailable'` accumulating in the
 * `LLM_Unavailable` list view, which is the detection surface that was firing the whole time.
 *
 * ⚠ SCOPE — ONE FIELD, DELIBERATELY. A repo-wide grep of `objects/**` for `LongTextArea` and
 * `<type>Html</type>` under any `__mdt` returns exactly one file:
 * `Broker_Protection_Config__mdt/fields/Extraction_Prompt__c.field-meta.xml`. So this class
 * selects that field and `DeveloperName` and NOTHING ELSE. The type's other seven fields are
 * Number / Text / Picklist, are NOT truncated, and are still served by `getInstance()` inside
 * `BrokerProtectionConfig` at zero SOQL cost. **Widening this SELECT would buy nothing and would
 * enlarge the surface of the mode question below.** The rule is now written down in
 * `.claude/skills/sf-apex/SKILL.md` and `ARCHITECTURE.md` §2 — read those before adding a second
 * long-text CMDT field anywhere.
 *
 * ═══ LAYER — WHY A `*Selector`, NOT A METHOD ON AN EXISTING `*Provider` ═══
 * Three classes in this repo read CMDT (`TaskGroupDefProvider`, `TransactionTaskDefProvider`,
 * `OnboardingTaskDefProvider`). They are named `*Provider` **specifically to signal that they
 * issue no SOQL**, and each says so in its header. Adding a SOQL method to one of them would
 * contradict all three. `*Selector` is the repo's name for "the class that owns the SOQL for
 * this object", which is exactly what this is — and it is the first selector in this repo to
 * query a `__mdt` type.
 *
 * ═══ COST — WHY THE CACHING LIVES IN THE CALLER, NOT HERE ═══
 * This class does not cache. `BrokerProtectionConfig.extractionPromptOverride()` holds the
 * lazy `promptLoaded` / `cachedPrompt` pair, so the read is **at most one SOQL per transaction,
 * and ZERO in any transaction that never builds an extraction callout** — which is every
 * trigger, every LWC controller, and every one of `PropertyMatchingService`'s claim paths. That
 * matters because `ExtractAddressQueueable` pins a QUERY_BUDGET (30 at N=1, 120 at N=10) against
 * an async cap of 200. A selector that cached internally would be a second, invisible cache
 * competing with that one; a caller that did not cache would pay this query per property.
 *
 * ⚠ Caching HERE would also defeat the test seam. `BrokerProtectionConfig.overrideForTest`
 * must be able to serve an injected row without this query ever running — see that method.
 *
 * ═══ BULK-TEST RULE — THE 251 MANDATE DOES NOT APPLY, AND THAT IS NOT A WAIVER ═══
 * Per `.claude/rules/bulk-test-rule.md`'s per-transaction-singleton carve-out:
 *   • the one method is a SINGLE-RECORD read by `DeveloperName`. No trigger, no batch, no loop
 *     — there is no second 200-record batch chunk to force, so 251 rows would exercise exactly
 *     zero additional code;
 *   • **a test cannot insert `__mdt` rows by DML at all**, so 251 rows here is not merely
 *     pointless, it is impossible;
 *   • the caller's static cache makes this structurally one query per transaction however many
 *     properties an inbound email carries.
 * The rule's "no SOQL/DML in loops" half is unaffected and still holds.
 *
 * @see BrokerProtectionConfig.cls (the sole caller; owns the cache, the defaulting and the seam)
 * @see LLMExtractionCalloutService.cls (owns the OpenAI boundary and the shipped fallback prompt)
 * @see .claude/skills/sf-apex/SKILL.md (the amended CMDT rule)
 * @see ARCHITECTURE.md §2 (the same rule, in Standards)
 */
public with sharing class BrokerProtectionConfigSelector {

    /**
     * The single `Broker_Protection_Config__mdt` row for `developerName`, carrying ONLY
     * `DeveloperName` and `Extraction_Prompt__c`.
     *
     * ⚠ READING ANY OTHER FIELD OFF THE RETURNED ROW RAISES `System.SObjectException`. That is
     * intentional — the other seven fields are correctly served by `getInstance()` and must not
     * migrate here. See the SCOPE note in the class header.
     *
     * NOT-FOUND CONTRACT — returns **null**, matching `getInstance()`'s measured behaviour
     * exactly (`usman-dpeg`, 2026-08-30: `getInstance('<missing>')` returns null, not an empty
     * row). This matters because "record absent" is a REACHABLE state in every freshly built
     * org: `.forceignore` excludes the `customMetadata` tree and file-based CMDT record deploy
     * throws UNKNOWN_EXCEPTION here, so the `Default` record is created by
     * `scripts/load-broker-protection-config.apex`, not by a deploy. A caller that treated
     * "absent" as an error would break every fresh org and every pre-loader test run.
     *
     * ═══ 🔴 MODE — `WITH SYSTEM_MODE`, AND THE ALTERNATIVE IS THE OUTAGE BEING FIXED ═══
     * ARCHITECTURE.md §2 requires the mode to be justified at the declaration, and requires
     * sharing to be judged as a SEPARATE question. Both, in order:
     *
     * 1. **This is an automation-path read in §2's literal sense** — performed on a principal's
     *    behalf, never at their request. It executes inside `ExtractAddressQueueable` →
     *    `LLMExtractionCalloutService.extract()` → `buildRequestBody()`, as the Email Service
     *    context user, on an inbound email nobody is watching. §2 names queueable-driven reads
     *    as exactly this case.
     * 2. **`USER_MODE` THROWS; IT DOES NOT DEGRADE — and here the throw is invisible.** One
     *    inaccessible field raises `System.QueryException: No such column`, an FLS denial
     *    wearing a schema error. On THIS path it lands in `ExtractAddressQueueable`'s degrade
     *    block and becomes `Outcome__c = 'New Lead (no property) — LLM unavailable'`: silently,
     *    with a SUCCESS-shaped pipeline. That is the exact failure mode this class exists to
     *    end. Choosing `USER_MODE` here would trade one silent outage for another, and every
     *    DPEG persona is on `Minimum Access` while a Metadata-API-deployed field arrives with
     *    no FLS for anyone, System Administrator included — so the denial is the DEFAULT state,
     *    not an edge case.
     * 3. **Do NOT justify this with "USER_MODE is inert on `__mdt` anyway."** `TaskGroupDefProvider`
     *    asserts that in its header, but it is an unverified in-repo claim. SYSTEM_MODE costs
     *    nothing and removes the dependence on it entirely.
     * 4. **Sharing is a NON-QUESTION here, and that is stated rather than left silent.** §2 is
     *    emphatic that SYSTEM_MODE lifts CRUD/FLS and NEVER sharing, so the sharing question
     *    must be asked separately every time. Asked here, it has no subject: a `__mdt` type has
     *    no sharing model, no OWD and no owner — there are no rows for anyone to be denied. So
     *    **no `private without sharing` inner class is needed, and none may be added.**
     * 5. **No permission set is touched by this change.** `customMetadataTypeAccesses` governs
     *    EDITING the record in Setup, not a runtime read; `Broker_Protection_Config__mdt` is
     *    `<visibility>Public</visibility>`, and `getInstance()` needed no grant either.
     *
     * @param developerName The record's `DeveloperName` (this repo uses `'Default'`); blank
     *                      returns null without querying.
     * @return The row with `DeveloperName` and `Extraction_Prompt__c` populated, or null when
     *         `developerName` is blank or no row matches.
     * @example
     * Broker_Protection_Config__mdt row =
     *     BrokerProtectionConfigSelector.selectByDeveloperName('Default');
     * String prompt = row == null ? null : row.Extraction_Prompt__c;
     */
    public static Broker_Protection_Config__mdt selectByDeveloperName(String developerName) {
        if (String.isBlank(developerName)) {
            return null;
        }

        List<Broker_Protection_Config__mdt> rows = [
            SELECT DeveloperName, Extraction_Prompt__c
            FROM Broker_Protection_Config__mdt
            WHERE DeveloperName = :developerName
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        return rows.isEmpty() ? null : rows[0];
    }
}
