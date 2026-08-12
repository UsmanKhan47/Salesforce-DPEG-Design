/**
 * Tests for SharePointConfig — the zero-SOQL accessor over the `SharePoint_Config__c` hierarchy
 * Custom Setting.
 *
 * ═══ WHY EVERY TEST INSERTS ITS OWN ORG-DEFAULT ROW (OR DELIBERATELY DOES NOT) ═══
 * Unlike `ContentPublicationBudget`, this class NEVER upserts — `settings()`'s own Javadoc states
 * that creating an empty row would only produce the same disabled default `isReady()` already
 * reports without writing anything. So a test that wants the ENABLED path must insert the org
 * default row itself (`SetupOwnerId = UserInfo.getOrganizationId()`, the standard mechanism for
 * writing a hierarchy Custom Setting's org-default row from Apex); a test that wants to prove the
 * "no row was ever created" case must insert nothing at all, which is also this class's default
 * starting state in every OTHER test in this suite (a fresh scratch/test context begins with zero
 * `SharePoint_Config__c` rows, since Custom Setting DATA is not deployable — see the class header).
 *
 * ═══ ZERO SOQL IS A CONTRACT, NOT AN IMPLEMENTATION DETAIL ═══
 * This accessor sits on the Closed Won trigger path (ARCHITECTURE.md §2), so several tests assert
 * `Limits.getQueries()` deltas of exactly zero — `getOrgDefaults()` is a platform cache read, and a
 * future change that turned it into a real SOQL statement would be a new way for a deal close to
 * get more expensive, invisibly, unless this suite catches it.
 *
 * @see SharePointConfig.cls
 * @author Unit Testing Agent
 */
@isTest
private class SharePointConfigTest {

    private static void insertOrgDefault(Boolean enabled, String siteId, String driveId, String parentFolderId) {
        SharePoint_Config__c config = new SharePoint_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Is_Enabled__c = enabled,
            Site_ID__c = siteId,
            Drive_ID__c = driveId,
            Parent_Folder_ID__c = parentFolderId
        );
        insert config;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // isReady() — every branch, and ZERO SOQL for each
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** 🔴 THE CASE THIS FEATURE IS BUILT AROUND: no org-default row exists at all. */
    @isTest
    static void isReady_noOrgDefaultRowExists_isFalse() {
        Test.startTest();
        Integer before = Limits.getQueries();
        Boolean ready = SharePointConfig.isReady();
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.isFalse(ready, 'With no org-default row, the feature must do nothing rather than guess');
        Assert.areEqual(0, spent, 'getOrgDefaults() must cost ZERO SOQL — it is a platform cache read');
    }

    @isTest
    static void isReady_rowExistsButDisabled_isFalse() {
        insertOrgDefault(false, 'contoso-site', null, null);

        Test.startTest();
        Boolean ready = SharePointConfig.isReady();
        Test.stopTest();

        Assert.isFalse(ready, 'Is_Enabled__c = false must disable the feature even with a valid site id');
    }

    @isTest
    static void isReady_enabledButBlankSiteId_isFalse() {
        insertOrgDefault(true, null, null, null);

        Test.startTest();
        Boolean ready = SharePointConfig.isReady();
        Test.stopTest();

        Assert.isFalse(ready,
            'A blank site id with the switch on must still refuse — there is nowhere to write to '
            + 'and there must be NO hardcoded fallback (design D7)');
    }

    @isTest
    static void isReady_enabledWithSiteId_isTrue() {
        insertOrgDefault(true, 'contoso-site', null, null);

        Test.startTest();
        Boolean ready = SharePointConfig.isReady();
        Test.stopTest();

        Assert.isTrue(ready, 'Enabled + a non-blank site id is the only condition that makes the feature ready');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // siteId() / driveId() / parentFolderId() — values, null-safety, ZERO SOQL, NO FALLBACK
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void siteIdDriveIdParentFolderId_returnTheConfiguredValues() {
        insertOrgDefault(true, 'the-site', 'the-drive', 'the-parent-item');

        Test.startTest();
        String siteId = SharePointConfig.siteId();
        String driveId = SharePointConfig.driveId();
        String parentFolderId = SharePointConfig.parentFolderId();
        Test.stopTest();

        Assert.areEqual('the-site', siteId, '');
        Assert.areEqual('the-drive', driveId, '');
        Assert.areEqual('the-parent-item', parentFolderId, '');
    }

    /** 🔴 NO HARDCODED FALLBACK. With no row at all, every accessor must return null — never a
     *  literal site id, which is exactly how production folders would land in a POC library. */
    @isTest
    static void siteIdDriveIdParentFolderId_noOrgDefaultRow_areAllNull_zeroSoql() {
        Test.startTest();
        Integer before = Limits.getQueries();
        String siteId = SharePointConfig.siteId();
        String driveId = SharePointConfig.driveId();
        String parentFolderId = SharePointConfig.parentFolderId();
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.isNull(siteId, 'No fallback — a missing configuration must read as null, not a guessed literal');
        Assert.isNull(driveId, '');
        Assert.isNull(parentFolderId, '');
        Assert.areEqual(0, spent, 'All three accessors together must cost ZERO SOQL');
    }

    /** Blank (not null) optional fields must also read as null, not empty string, so callers can
     *  use a simple `String.isNotBlank` check uniformly. */
    @isTest
    static void driveIdAndParentFolderId_blankOnTheRow_readAsNull() {
        insertOrgDefault(true, 'the-site', null, null);

        Test.startTest();
        String driveId = SharePointConfig.driveId();
        String parentFolderId = SharePointConfig.parentFolderId();
        Test.stopTest();

        Assert.isNull(driveId, 'A blank optional field must read as null, meaning "use the site default"');
        Assert.isNull(parentFolderId, 'A blank optional field must read as null, meaning "use the drive root"');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // unavailableReason() — two DIFFERENT admin actions get two DIFFERENT messages
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void unavailableReason_noOrgDefaultRow_namesEnablingTheSetting() {
        Test.startTest();
        String reason = SharePointConfig.unavailableReason();
        Test.stopTest();

        Assert.isTrue(reason.contains('SharePoint_Config__c'), 'Actual: ' + reason);
        Assert.isTrue(reason.contains('Is_Enabled__c'),
            'With no row at all, the fix is to CREATE and enable one. Actual: ' + reason);
    }

    @isTest
    static void unavailableReason_disabled_namesEnablingTheSetting() {
        insertOrgDefault(false, 'contoso-site', null, null);

        Test.startTest();
        String reason = SharePointConfig.unavailableReason();
        Test.stopTest();

        Assert.isTrue(reason.contains('Is_Enabled__c'), 'Actual: ' + reason);
    }

    /** The "switched on but unusable" case names a DIFFERENT admin action than "switched off" —
     *  populating the site id, not flipping the checkbox. Conflating the two would leave a reader
     *  guessing which of two different fixes to make. */
    @isTest
    static void unavailableReason_enabledButNoSiteId_namesPopulatingTheSiteId() {
        insertOrgDefault(true, null, null, null);

        Test.startTest();
        String reason = SharePointConfig.unavailableReason();
        Test.stopTest();

        Assert.isTrue(reason.contains('Site_ID__c'), 'Actual: ' + reason);
        Assert.isFalse(reason.contains('Is_Enabled__c'),
            'This is a DIFFERENT admin action than enabling the switch — the two messages must not '
            + 'be conflated, or a reader fixes the wrong thing. Actual: ' + reason);
    }

    @isTest
    static void unavailableReason_readyState_stillReturnsAString() {
        // Not a state unavailableReason is ever called for in production (DealFolderService only
        // calls it when isReady() is false), but it must not throw or return null defensively.
        insertOrgDefault(true, 'contoso-site', null, null);

        Test.startTest();
        String reason = SharePointConfig.unavailableReason();
        Test.stopTest();

        Assert.isNotNull(reason, 'Must never return null, even for an unexpected call pattern');
    }
}
