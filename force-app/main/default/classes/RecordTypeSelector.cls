/**
 * Selector for RecordType. Encapsulates ALL SOQL against RecordType per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live
 * in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave G. Sole consumer: LeadConvertService.stampConvertedOpportunities
 * — resolves the Opportunity 'Land' / 'Retail' record types by DeveloperName so
 * a converted lead's Deal Type lands the deal on the correct sales path.
 *
 * MODE — `WITH USER_MODE` (API 67). RecordType is a system object: it has no
 * record-level sharing, and the fields selected (Id, DeveloperName) and filtered
 * (SobjectType, DeveloperName) are all non-permissionable, so RecordType FLS is
 * inert. USER_MODE therefore returns exactly the same rows the original no-WITH
 * (system-mode) query returned and cannot throw for any profile — every user can
 * read RecordType. No SYSTEM_MODE path is needed here (contrast
 * ProcessInstanceStepSelector, whose audit read genuinely needs system visibility).
 *
 * NOT-FOUND CONTRACT — read-for-lookup: returns a List (never null). Callers build
 * their own DeveloperName -> Id map; a missing record type simply does not appear.
 *
 * STATIC SOQL with bind variables (SobjectType + DeveloperName set) — the original
 * LeadConvertService query was static; both filter values are bound, never
 * concatenated, so there is no SOQL-injection surface.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class RecordTypeSelector {

    /**
     * Record types for one SObject whose DeveloperName is in the requested set —
     * backs LeadConvertService's Land / Retail record-type resolution.
     *
     * @param sobjectType    The SObject API name (e.g. 'Opportunity'); blank-safe.
     * @param developerNames The RecordType DeveloperNames to match (bound with IN);
     *                       null/empty-safe.
     * @return Matching RecordType rows (Id, DeveloperName); an empty list when
     *         sobjectType is blank, developerNames is null/empty, or nothing matches
     *         (never null).
     * @example
     * List<RecordType> types = RecordTypeSelector.selectByObjectAndDeveloperNames(
     *     'Opportunity', new Set<String>{ 'Land', 'Retail' });
     */
    public static List<RecordType> selectByObjectAndDeveloperNames(
        String sobjectType,
        Set<String> developerNames
    ) {
        if (String.isBlank(sobjectType) || developerNames == null || developerNames.isEmpty()) {
            return new List<RecordType>();
        }
        return [
            SELECT Id, DeveloperName
            FROM RecordType
            WHERE SobjectType = :sobjectType AND DeveloperName IN :developerNames
            WITH USER_MODE
        ];
    }
}
