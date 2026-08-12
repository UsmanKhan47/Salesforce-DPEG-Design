/**
 * Configuration accessor for the SharePoint deal-folder feature — the site, the drive, the
 * optional parent folder, and the master on/off switch.
 *
 * ═══ WHY A HIERARCHY CUSTOM SETTING AND NOT A CONSTANT OR CUSTOM METADATA (design D7) ═══
 * • An Apex CONSTANT is compile-checked and deployable, and WRONG: a site id is per-environment,
 *   and shipping the POC site id in code is how production deal folders end up in a POC library.
 * • CUSTOM METADATA is eliminated by MEASUREMENT, not preference: there is no `customMetadata/`
 *   directory in this repo at all, and CMDT *record* deploys fail in this org with
 *   `UNKNOWN_EXCEPTION` and need an Apex loader (recorded verbatim in
 *   `RecordStageAdvanceService`'s header). A config mechanism that cannot be deployed is not a
 *   config mechanism.
 * • A HIERARCHY CUSTOM SETTING follows the one existing precedent, `ContentPublicationBudget` /
 *   `Content_Publication_Budget__c`, chosen there for the same reason it matters here:
 *   `getOrgDefaults()` reads the platform cache and costs **ZERO SOQL**. This accessor is
 *   consulted on the CLOSED WON path, inside an after-update trigger, where every query added is
 *   a new way for a deal close to get more expensive.
 *
 * ═══ 🔴 THERE IS NO FALLBACK, AND ADDING ONE WOULD BE A DEFECT ═══
 * `isReady()` returns false when the org-default row is absent, when `Is_Enabled__c` is false, or
 * when `Site_ID__c` is blank. The feature then does NOTHING and stamps `Skipped`. It is tempting
 * to "helpfully" default the site id to the one the developer tested against; that is precisely
 * the failure this note exists to prevent — a silent default is indistinguishable from correct
 * configuration until deal documents are discovered in the wrong tenant's library.
 *
 * ═══ ⚠ IT DEGRADES TO **DISABLED**, THE OPPOSITE OF `ContentPublicationBudget` ═══
 * That class fails OPEN (a malfunctioning backstop must not block a working feature). This one
 * fails CLOSED, and the asymmetry is deliberate: a backstop that cannot read its own state should
 * get out of the way, whereas an INTEGRATION that cannot read WHERE to write must not guess. The
 * cost of failing closed here is a `Skipped` stamp a human can see and re-drive; the cost of
 * failing open is an external write to an unknown destination.
 *
 * ⚠ CUSTOM-SETTING **DATA** IS NOT DEPLOYABLE METADATA. There is no org-default row in source
 * control and there never will be. Unlike `ContentPublicationBudget`, this class does NOT create
 * one at runtime — creating a row would only produce a disabled, site-less default, which is
 * exactly the state `isReady()` already reports without writing anything. Populating it is a
 * named POST-DEPLOY GATE (design §8 step 7).
 *
 * ⚠ ONLY THE ORG DEFAULT IS EVER READ (`getOrgDefaults()`, never `getInstance()`). A per-user
 * override would let two users write deal folders into two different libraries, which no reader of
 * `Property__c.SharePoint_Folder_URL__c` could ever detect.
 *
 * LAYER — configuration accessor. ZERO SOQL (the hierarchy custom-setting read is a cache lookup,
 * not a query), ZERO DML, no callouts. `with sharing` per ARCHITECTURE.md §2; functionally a no-op
 * because hierarchy custom settings are not sharing-controlled records.
 *
 * @see ContentPublicationBudget.cls (the precedent, and the deliberate fail-open/fail-closed contrast)
 * @see DealFolderService.cls        (the only caller)
 * @see ARCHITECTURE.md §3.4
 */
public with sharing class SharePointConfig {

    /**
     * Copy stamped into `Property__c.SharePoint_Folder_Error__c` alongside `Skipped` when the
     * feature is switched off or unconfigured. It names the setting so the reader can act.
     *
     * 🔴 BOTH MESSAGES BELOW MUST NAME **TWO** STEPS, AND THE SECOND ONE IS THE EASY ONE TO DROP.
     * Fixing the configuration does NOT re-drive an already-`Skipped` row: the sweeper's locator is
     * `SharePoint_Folder_Status__c IN ('Pending','Failed')` (`PropertySelector.folderSweepLocator`),
     * so `Skipped` and NULL are permanently outside it, and CLEARING the status moves the row from
     * one excluded state to another rather than into the queue. Setting the status to `Pending` is
     * the only action that returns the row to the sweep. Re-saving the closed deal does not work
     * either — the trigger keys on stage ENTRY (`DealFolderService` residual R5).
     */
    @TestVisible private static final String REASON_DISABLED =
        'SKIPPED: the SharePoint deal-folder integration is switched off. TO RECOVER: set '
        + 'SharePoint_Config__c (org default) Is_Enabled__c = true and populate Site_ID__c, THEN '
        + 'set SharePoint_Folder_Status__c to Pending on this record — that second step is the ONLY '
        + 'action that returns it to the daily sweep. Enabling the setting alone changes nothing '
        + 'for this record, and CLEARING this status hides it from the sweep permanently.';

    /** Copy for the "switched on but unusable" case, which is a different admin action. */
    @TestVisible private static final String REASON_NO_SITE =
        'SKIPPED: SharePoint_Config__c is enabled but Site_ID__c is blank, so there is no library '
        + 'to write to. TO RECOVER: populate Site_ID__c on the ORG DEFAULT row, THEN set '
        + 'SharePoint_Folder_Status__c to Pending on this record — that second step is the ONLY '
        + 'action that returns it to the daily sweep. Populating Site_ID__c alone changes nothing '
        + 'for this record, and CLEARING this status hides it from the sweep permanently.';

    /**
     * Whether the feature is configured well enough to make a callout at all. ZERO SOQL, ZERO DML.
     *
     * @return true only when the org-default row exists, `Is_Enabled__c` is true and `Site_ID__c`
     *         is non-blank. Any read failure resolves to false (see the class header — fail closed).
     * @example
     * if (!SharePointConfig.isReady()) { stampSkipped(SharePointConfig.unavailableReason()); return; }
     */
    public static Boolean isReady() {
        try {
            SharePoint_Config__c config = settings();
            return config != null
                && config.Is_Enabled__c == true
                && String.isNotBlank(config.Site_ID__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'SharePointConfig.isReady: degrading to DISABLED after '
                + e.getTypeName() + ' | ' + e.getMessage());
            return false;
        }
    }

    /**
     * The Graph site id. ZERO SOQL.
     *
     * @return `Site_ID__c` from the org default, or null when unreadable. Callers must not
     *         substitute a literal — see the class header.
     * @example
     * String siteId = SharePointConfig.siteId();
     */
    public static String siteId() {
        SharePoint_Config__c config = settingsOrNull();
        return (config == null) ? null : config.Site_ID__c;
    }

    /**
     * The optional explicit drive (document library) id. ZERO SOQL.
     *
     * Blank is the expected value and means "the site's default document library", which is what
     * `SharePointCalloutService` addresses as `/sites/{siteId}/drive`. It is read and honoured
     * rather than ignored so that a site carrying several libraries cannot silently receive deal
     * folders in the wrong one — a config field nothing reads is a trap for the next admin.
     *
     * @return `Drive_ID__c`, or null.
     * @example
     * String driveId = SharePointConfig.driveId();
     */
    public static String driveId() {
        SharePoint_Config__c config = settingsOrNull();
        return (config == null) ? null : config.Drive_ID__c;
    }

    /**
     * The optional parent folder item id. ZERO SOQL.
     *
     * Blank — the expected production value — means deal folders are created at the LIBRARY ROOT.
     * A populated value nests every deal folder beneath that item, which is a one-field change
     * requiring no code and no deploy.
     *
     * @return `Parent_Folder_ID__c`, or null for the drive root.
     * @example
     * String parent = SharePointConfig.parentFolderId();
     */
    public static String parentFolderId() {
        SharePoint_Config__c config = settingsOrNull();
        return (config == null) ? null : config.Parent_Folder_ID__c;
    }

    /**
     * The human-readable reason the feature is not ready, for the `Skipped` stamp.
     *
     * Two distinct messages, because they name two DIFFERENT admin actions: switching the feature
     * on, versus supplying the site it writes to. One generic "not configured" line would leave a
     * reader guessing which.
     *
     * @return The reason text; the "switched off" copy when the state cannot be read at all.
     * @example
     * DealFolderService.stampSkipped(ids, SharePointConfig.unavailableReason());
     */
    public static String unavailableReason() {
        try {
            SharePoint_Config__c config = settings();
            if (config == null || config.Is_Enabled__c != true) {
                return REASON_DISABLED;
            }
            return String.isBlank(config.Site_ID__c) ? REASON_NO_SITE : REASON_DISABLED;
        } catch (Exception e) {
            return REASON_DISABLED;
        }
    }

    /**
     * The org-default row, or null when it cannot be read at all.
     *
     * 🔴 THE THREE ACCESSORS ABOVE READ THEIR FIELDS **STATICALLY** (`config.Site_ID__c`), AND THAT
     * IS A CORRECTNESS REQUIREMENT, NOT A STYLE PREFERENCE. They previously went through a shared
     * `valueOf(String fieldName)` helper using `config.get('Site_ID__c')`, which is dynamic: a
     * renamed or mistyped field name COMPILES, throws `SObjectException` at runtime, is swallowed
     * by the catch, and returns null — while `isReady()`, which reads the same field statically,
     * still returns TRUE. The feature would then be reported healthy while making ZERO callouts,
     * because `SharePointCalloutService` refuses a blank site id and `DealFolderService` stamps
     * nothing to look at. Static access makes that state a COMPILE failure instead: rename
     * `Site_ID__c` and this class stops deploying, which is exactly the signal wanted.
     *
     * ⚠ Keep every reader of this custom setting statically typed for the same reason — including
     * `isReady()` and `unavailableReason()`, which already are. A dynamic read here is a silent
     * disable switch wearing a healthy status.
     *
     * @return The settings row, or null when the read itself failed (fail closed — see the class
     *         header).
     */
    private static SharePoint_Config__c settingsOrNull() {
        try {
            return settings();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'SharePointConfig.settingsOrNull: ' + e.getTypeName() + ' | ' + e.getMessage());
            return null;
        }
    }

    /**
     * The org-default custom-setting row.
     *
     * `getOrgDefaults()` returns an EMPTY INSTANCE rather than null when no row has ever been
     * written — which is why `isReady()` tests the field values and not the reference. ⚠ Unlike
     * `ContentPublicationBudget.settings()`, this method never upserts: creating an empty,
     * disabled row would add a DML statement to the Closed Won path to record a state that is
     * already the default answer.
     *
     * @return The org-default settings row; never queried, always cache-read (0 SOQL).
     */
    private static SharePoint_Config__c settings() {
        SharePoint_Config__c config = SharePoint_Config__c.getOrgDefaults();
        return (config == null) ? new SharePoint_Config__c() : config;
    }
}
