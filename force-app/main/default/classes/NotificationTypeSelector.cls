/**
 * Selector for CustomNotificationType. Encapsulates ALL SOQL against
 * CustomNotificationType per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A2 (Acquisitions — Deal Support). Consumer: BrokerPortalNotifier
 * (the guest/automation Broker-Portal lead-intake notification path).
 *
 * MODE — `WITH SYSTEM_MODE` (API 67), justified: this selector is invoked only
 * from BrokerPortalNotifier, which runs in the guest/automation context of the
 * public Broker Portal. CustomNotificationType is a setup/metadata object with no
 * guest FLS, and the guest profile's FLS lives on the non-deployable Guest Profile
 * (P3's guest FLS spike never completed). Per the P4 design §5, the guest path is
 * NOT placed under USER_MODE unverified. This is a DeveloperName -> Id lookup of a
 * notification type definition, not user record data.
 *
 * NOT-FOUND CONTRACT — a missing notification type is a normal "not configured"
 * state; the caller already treats it as "skip notification". Returns
 * SObject-or-null (never throws) to preserve that.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #23, §5)
 */
public with sharing class NotificationTypeSelector {

    /**
     * The CustomNotificationType matching a DeveloperName — backs
     * BrokerPortalNotifier's lookup of the "Broker_Portal_New_Lead" type.
     *
     * @param developerName CustomNotificationType.DeveloperName to match; null-safe.
     * @return The matching CustomNotificationType (Id populated), or null when the
     *         input is blank or no type is configured with that DeveloperName.
     */
    public static CustomNotificationType selectByDeveloperName(String developerName) {
        if (String.isBlank(developerName)) {
            return null;
        }
        List<CustomNotificationType> types = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :developerName
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return types.isEmpty() ? null : types[0];
    }
}
