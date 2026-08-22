/**
 * Selector for `StaticResource`. Encapsulates the SOQL that reads a static resource body, per
 * ARCHITECTURE.md section 2 and .claude/rules/apex-layering-rule.md.
 *
 * MODE - `WITH SYSTEM_MODE` on `selectBodyByName`, an AUTOMATION-PATH read in the strict sense
 * ARCHITECTURE.md section 2 defines: it happens on a scheduled job's behalf, not at a human's
 * request. Under `USER_MODE` a running principal without read on `StaticResource` would make the
 * query THROW rather than degrade, killing the nightly run and destroying the `Sync_Run__c` audit
 * row that is the halt rule's only evidence.
 *
 * SHARING - `with sharing`, deliberately NOT escaped. `StaticResource` has no sharing model to
 * escape. Adding a `without sharing` inner class here would cargo-cult the pattern from
 * `CaseSelector`, where it is load-bearing, into a place where it buys nothing and dilutes the
 * signal that the pattern is exceptional.
 *
 * @see StubReceivablesFeedProvider.cls (the only caller)
 */
public with sharing class StaticResourceSelector {

    /**
     * The UTF-8 body of one static resource.
     *
     * @param resourceName The `StaticResource.Name`; blank-safe.
     * @return The decoded body, or null when the resource does not exist or has no body. Null is a
     *         first-class answer - `StubReceivablesFeedProvider` turns it into a recorded halt
     *         rather than an empty feed.
     * @example
     * String json = StaticResourceSelector.selectBodyByName('Receivables_Feed_Sample');
     */
    public static String selectBodyByName(String resourceName) {
        if (String.isBlank(resourceName)) {
            return null;
        }
        List<StaticResource> resources = [
            SELECT Id, Body
            FROM StaticResource
            WHERE Name = :resourceName
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (resources.isEmpty() || resources[0].Body == null) {
            return null;
        }
        return resources[0].Body.toString();
    }
}
