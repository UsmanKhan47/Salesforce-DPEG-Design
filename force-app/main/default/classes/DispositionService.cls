/**
 * Service for the Disposition (closing) write workflow.
 *
 * Owns the business logic behind DispositionController.findOrCreate (P6 controller
 * thinning): the idempotent "find the Property Asset's current Disposition, or create
 * one" operation. Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2, this
 * DML is Service work, not Controller work — the controller now only marshals input,
 * delegates here, and maps failures to an AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to DispositionSelector and PropertyAssetSelector — this service
 * holds no inline SOQL. It throws the raw platform DmlException on a save failure and the
 * raw SellMeterGateException on a refusal; the AuraHandledException boundary lives in the
 * controller, NOT here, so the service stays UI-agnostic (also callable from Flow / Apex /
 * a future caller).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * THE SERVER-SIDE SELL-METER GATE (design §5.1)
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Before this change the red-band block existed ONLY in lwc/sellMeterList
 * (`actionDisabled: meter === 'RED'`), so any caller invoking the @AuraEnabled method
 * directly could open a disposition on an asset the business had said was not ready to
 * sell. The band is now computed server-side from the same SellMeterService.bandForPeak
 * the dashboard uses, so client and server cannot disagree.
 *
 * 🔴 THE GATE APPLIES TO THE CREATE BRANCH ONLY, AND THAT IS LOAD-BEARING. If a
 * Disposition already exists this method returns its Id UNCHANGED, no band read, no
 * refusal. An asset's Peak_Sell_Date__c drifts with the market, so an already-open
 * disposition would become unreachable the moment its asset re-banded RED — breaking
 * navigation to a live deal for a reason nobody asked for. The gate answers "may this be
 * STARTED?", never "may this be OPENED?".
 *
 * 🔴 YELLOW IS PERMITTED, NOT REFUSED. The yellow band is what the dashboard's Override
 * button exists for (Gate 1 Q2 = confirm-then-create). Refusing YELLOW here would make
 * that button a server-side dead end for the second time in this module's life.
 *
 * RECORD TYPE (Gate 1 Q1 = (a)): the create branch stamps On_Market EXPLICITLY. Both
 * disposition paths start identically at Disposition Readiness, so the type is not
 * knowable from the sell meter; an off-market deal is switched by changing the record type
 * early, while the record is still at Readiness. The alternative — leaving RecordTypeId
 * null and inheriting the running user's PROFILE DEFAULT — was rejected because
 * `profiles/**` is .forceignore'd, making that behaviour org state this repo can neither
 * set nor verify. The stamp is guarded on isAvailable() so a user without the record type
 * (or an org where §4 has not deployed yet) falls back to the platform default rather than
 * throwing: a missing record type must not block a disposition.
 *
 * GOVERNOR BUDGET: 1 SOQL on the existing-Disposition path; 2 SOQL / 1 DML on the create
 * path. The record-type lookup is a describe, not a query, so it costs nothing.
 *
 * BULK: findOrCreate is structurally single-record-per-transaction — no trigger, no loop,
 * one invocation per LWC click. See DispositionServiceTest's header for the
 * .claude/rules/bulk-test-rule.md exemption and its reasoning.
 *
 * @see force-app/main/default/classes/DispositionController.cls (thin caller)
 * @see force-app/main/default/classes/DispositionSelector.cls (Disposition SOQL)
 * @see force-app/main/default/classes/PropertyAssetSelector.cls (peak-date SOQL)
 * @see force-app/main/default/classes/SellMeterService.cls (the shared band function)
 */
public with sharing class DispositionService {

    /**
     * A DESIGNED REFUSAL, not a platform failure — which is the whole reason it is a named
     * type rather than a bare Exception. DispositionController.findOrCreate catches this
     * FIRST and rethrows its message verbatim to the user; everything else falls through to
     * the generic write-failure catch beneath it. Without the distinction a deliberate,
     * permanent "this property is not ready to sell" would reach the user as "This change
     * could not be saved. Refresh the page and try again" — advice that can never work.
     *
     * Its message is therefore USER-SAFE BY CONSTRUCTION: it is authored here, contains no
     * platform text, no field API names and no exception detail, and is safe to surface
     * verbatim. Any future message added to this type must hold that property.
     */
    public class SellMeterGateException extends Exception {}

    /** Developer name of the record type every Sell-Meter-created disposition is stamped with. */
    @TestVisible
    private static final String ON_MARKET_RECORD_TYPE = 'On_Market';

    // The user-facing refusal for a RED asset. Plain ASCII on purpose (the repo's other
    // user-safe controller messages are too) and phrased as the business rule, not as an
    // error: the user has done nothing wrong, the property simply is not ready yet.
    @TestVisible
    private static final String RED_BAND_REFUSAL =
        'This property is not ready to sell - its peak sell date is more than 90 days away, '
        + 'so a disposition cannot be initiated yet.';

    /**
     * Returns the most-recent Disposition for a Property Asset, creating one when none
     * exists yet — the find-or-create the Disposition dashboard button relies on so the
     * closing workspace self-seeds on first open. Idempotent: a second call for an asset
     * that already has a Disposition returns the existing Id and creates nothing.
     *
     * On the CREATE branch only, the asset's sell-meter band is checked and a RED asset is
     * refused (see the class header). YELLOW and GREEN both create.
     *
     * @param assetId the Property_Asset__c to read/create the Disposition under
     * @return the existing or newly created Disposition__c Id
     * @throws DispositionService.SellMeterGateException when no Disposition exists yet and
     *         the asset's peak sell date bands RED (more than 90 days out, or absent)
     * @throws System.QueryException when the create branch is reached and assetId does not
     *         resolve to a Property_Asset__c
     * @throws System.DmlException on a platform save failure
     */
    public static Id findOrCreate(Id assetId) {
        Disposition__c existing = DispositionSelector.selectMostRecentByPropertyAssetId(assetId);
        if (existing != null) {
            // EXISTING-RECORD EARLY RETURN — deliberately ahead of the gate. See the class
            // header: the sell meter governs starting a disposition, never reopening one.
            return existing.Id;
        }

        Property_Asset__c asset = PropertyAssetSelector.selectPeakSellDateById(assetId);
        if (SellMeterService.BAND_RED == SellMeterService.bandForPeak(asset.Peak_Sell_Date__c)) {
            throw new SellMeterGateException(RED_BAND_REFUSAL);
        }

        Disposition__c d = new Disposition__c(Property_Asset__c = assetId);
        Id onMarketId = onMarketRecordTypeId();
        if (onMarketId != null) {
            d.RecordTypeId = onMarketId;
        }
        insert d;
        return d.Id;
    }

    /**
     * The On_Market record type Id, or null when it does not exist in this org or is not
     * available to the running user.
     *
     * Null is a legitimate answer, not an error: the caller then leaves RecordTypeId unset
     * and the platform applies its own default. This keeps a disposition creatable in an
     * org where the §4 record-type metadata has not deployed yet, and keeps a user who was
     * never granted the record type from being blocked by a stamp they did not ask for.
     *
     * A describe, not a query — it costs no SOQL.
     */
    private static Id onMarketRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(ON_MARKET_RECORD_TYPE);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }
}
