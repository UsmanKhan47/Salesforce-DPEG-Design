/**
 * Backs the meter register list (`c/meterRegister`) and the UT-001 meter capture screen
 * (`c/utilityMeterCapture`).
 *
 * THIN by contract (P6 controller thinning, `.claude/rules/apex-layering-rule.md`): no SOQL,
 * no DML and no business rules live here. Reads go to `MeterSelector` / `UnitSelector` /
 * `UtilityBillSelector`; the write goes to `MeterCaptureService`. What IS here is the
 * mapping from records to the flat, pre-formatted shapes an LWC datatable needs, and the
 * error boundary.
 *
 * ERROR BOUNDARY (ARCHITECTURE.md section 5): every `@AuraEnabled` method maps a failure to
 * an `AuraHandledException` carrying a FIXED, generic message. Platform detail goes to the
 * debug log, which is admin-only. Concatenating `e.getMessage()` into a user-facing string
 * leaks schema and stack detail to whoever can open the page; the pattern below is copied
 * from `WorkOrderController` lines 16-23 deliberately so all PM controllers fail alike.
 */
public with sharing class UtilityMeterController {

    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';
    private static final String SAVE_FAILURE_MESSAGE =
        'The meters could not be saved. Check the values and try again, or contact your '
        + 'administrator if the problem continues.';

    /**
     * `AuraHandledException` needs BOTH the constructor argument and `setMessage` - without
     * the second call the client receives "Script-thrown exception" and the message is lost.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    // ===================== meter register =====================

    /** One meter as the register datatable renders it. Every value is display-ready. */
    public class RegisterRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String meterNumber;
        @AuraEnabled public String utilityType;
        @AuraEnabled public String unitLabel;
        @AuraEnabled public String providerName;
        @AuraEnabled public String utilityAccountNumber;
        @AuraEnabled public String serviceIdentifier;
        @AuraEnabled public String paidBy;
        @AuraEnabled public String serviceStatus;
        @AuraEnabled public Decimal registerSize;
        /** True when this meter hangs off another meter (FSD 5.10.3 master / sub-meter). */
        @AuraEnabled public Boolean isSubMeter;
        /** The master's meter number, so a sub-meter reads as "under 1234" without a join. */
        @AuraEnabled public String masterMeterNumber;
        /** Sum of `Meter_Allocation__c.Allocation_Pct__c`; null on an unshared meter. */
        @AuraEnabled public Decimal totalAllocatedPct;
        /** The newest bill's total charges, or null when the meter has never been billed. */
        @AuraEnabled public Decimal latestTotalCharges;
        /** The newest bill's read date. */
        @AuraEnabled public Date latestReadDate;
        /** The newest bill's dollar variance against its own prior bill. */
        @AuraEnabled public Decimal latestVarianceAmount;
        /**
         * The newest bill's percentage variance, read from
         * `Utility_Bill__c.Total_Variance_Pct__c`. Null when the bill has no prior, which
         * the register renders as a blank rather than as a 0% "no change".
         */
        @AuraEnabled public Decimal latestVariancePct;
        @AuraEnabled public Id latestBillId;
    }

    /**
     * The meter register for one property, newest billing figures attached.
     *
     * TWO queries regardless of meter count: one for the meters, one for their bills. The
     * bills are fetched in a single `IN :meterIds` read and reduced in memory, never one
     * query per meter.
     *
     * @param propertyAssetId The property whose register is wanted.
     * @return Register rows, master meters before sub-meters; empty when there are none.
     * @throws AuraHandledException on any read failure, with a fixed generic message.
     */
    @AuraEnabled(cacheable=true)
    public static List<RegisterRow> getRegister(Id propertyAssetId) {
        try {
            List<Meter__c> meters =
                MeterSelector.selectByPropertyAssetIds(new Set<Id>{ propertyAssetId });
            if (meters.isEmpty()) {
                return new List<RegisterRow>();
            }
            Map<Id, Utility_Bill__c> latestByMeter = latestBillByMeter(meters);

            List<RegisterRow> rows = new List<RegisterRow>();
            for (Meter__c m : meters) {
                RegisterRow r = new RegisterRow();
                r.id = m.Id;
                r.name = m.Name;
                r.meterNumber = m.Meter_Number__c;
                r.utilityType = m.Utility_Type__c;
                r.unitLabel = (m.Unit__c == null || m.Unit__r == null)
                    ? 'Whole building'
                    : m.Unit__r.Suite_Number__c;
                r.providerName = m.Provider_Name__c;
                r.utilityAccountNumber = m.Utility_Account_Number__c;
                r.serviceIdentifier = m.Service_Identifier__c;
                r.paidBy = m.Paid_By__c;
                r.serviceStatus = m.Service_Status__c;
                r.registerSize = m.Register_Size__c;
                r.isSubMeter = m.Master_Meter__c != null;
                r.masterMeterNumber =
                    (m.Master_Meter__c == null || m.Master_Meter__r == null)
                        ? null
                        : m.Master_Meter__r.Meter_Number__c;
                r.totalAllocatedPct = m.Total_Allocated_Pct__c;

                Utility_Bill__c latest = latestByMeter.get(m.Id);
                if (latest != null) {
                    r.latestBillId = latest.Id;
                    r.latestReadDate = latest.Read_Date__c;
                    r.latestTotalCharges = latest.Total_Charges_Amount__c;
                    r.latestVarianceAmount = latest.Total_Variance_Amount__c;
                    r.latestVariancePct = latest.Total_Variance_Pct__c;
                }
                rows.add(r);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'UtilityMeterController.getRegister on '
                + propertyAssetId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Newest bill per meter, from ONE query over all of them.
     *
     * The selector already orders newest read first, so the first row seen for a meter is
     * its latest and later rows are skipped - no sorting and no per-meter query.
     *
     * The row cap is meters x 6: enough that every meter is represented even when the
     * property's meters are billed on wildly different cycles, without pulling a whole
     * billing history to display one number. A meter whose last six sibling reads all
     * belong to other meters simply shows no figures, which is the same as never billed.
     */
    private static Map<Id, Utility_Bill__c> latestBillByMeter(List<Meter__c> meters) {
        Set<Id> meterIds = new Set<Id>();
        for (Meter__c m : meters) {
            meterIds.add(m.Id);
        }
        Map<Id, Utility_Bill__c> latestByMeter = new Map<Id, Utility_Bill__c>();
        for (Utility_Bill__c bill :
                UtilityBillSelector.selectRecentByMeterIds(meterIds, meterIds.size() * 6)) {
            if (!latestByMeter.containsKey(bill.Meter__c)) {
                latestByMeter.put(bill.Meter__c, bill);
            }
        }
        return latestByMeter;
    }

    // ===================== capture screen (UAT UT-001) =====================

    /** One space on the capture grid. */
    public class UnitOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String label;
        @AuraEnabled public String status;
    }

    /** Everything `c/utilityMeterCapture` needs to draw itself. */
    public class CaptureModel {
        @AuraEnabled public Id propertyAssetId;
        /** The spaces at this property, in suite order. May be empty. */
        @AuraEnabled public List<UnitOption> units = new List<UnitOption>();
        /** Meters already on the register, so the screen edits rather than duplicates them. */
        @AuraEnabled public List<MeterCaptureService.MeterRow> existingMeters =
            new List<MeterCaptureService.MeterRow>();
    }

    /**
     * The capture screen's starting state for one property.
     *
     * Deliberately returns the EXISTING meters rather than an empty grid. UT-001 fires when
     * the onboarding utility-transfer task is completed, and that task can be completed more
     * than once in a property's life (re-opened, corrected, a second transfer); an empty grid
     * would invite a duplicate register.
     *
     * The property NAME is not returned here either: the opening component already knows it
     * (from its own record page or from the Onboarding it was launched from) and passes it in
     * as a property, so this method adds no query for a string the caller is holding.
     *
     * Picklist values are NOT returned here. The component reads them from Lightning Data
     * Service (`getPicklistValues`), which is the ARCHITECTURE.md section 5 LDS-first rule
     * and means a new `Utility_Type__c` value appears in the UI with no Apex change.
     *
     * @param propertyAssetId The property being captured.
     * @return The model; `units` and `existingMeters` may each be empty but are never null.
     * @throws AuraHandledException on any read failure, with a fixed generic message.
     */
    @AuraEnabled(cacheable=true)
    public static CaptureModel getCaptureModel(Id propertyAssetId) {
        try {
            CaptureModel model = new CaptureModel();
            model.propertyAssetId = propertyAssetId;

            for (Unit__c u : UnitSelector.selectSuitesByPropertyAssetId(propertyAssetId)) {
                UnitOption opt = new UnitOption();
                opt.id = u.Id;
                opt.label = String.isBlank(u.Suite_Number__c) ? 'Unnamed space' : u.Suite_Number__c;
                opt.status = u.Status__c;
                model.units.add(opt);
            }
            for (Meter__c m : MeterSelector.selectForCapture(propertyAssetId)) {
                MeterCaptureService.MeterRow row = new MeterCaptureService.MeterRow();
                row.meterId = m.Id;
                row.unitId = m.Unit__c;
                row.unitLabel = (m.Unit__c == null || m.Unit__r == null)
                    ? 'Whole building'
                    : m.Unit__r.Suite_Number__c;
                row.meterNumber = m.Meter_Number__c;
                row.utilityType = m.Utility_Type__c;
                row.utilityAccountNumber = m.Utility_Account_Number__c;
                row.serviceIdentifier = m.Service_Identifier__c;
                row.providerName = m.Provider_Name__c;
                row.paidBy = m.Paid_By__c;
                row.paidByReason = m.Paid_By_Reason__c;
                row.registerSize = m.Register_Size__c;
                row.serviceStatus = m.Service_Status__c;
                model.existingMeters.add(row);
            }
            return model;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'UtilityMeterController.getCaptureModel on '
                + propertyAssetId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Saves the capture grid. One call, one transaction, at most two DML statements.
     *
     * NOT `cacheable` - it writes.
     *
     * @param propertyAssetId The property every row belongs to.
     * @param rows            The grid; untouched lines are ignored by the service.
     * @return What was created, updated and skipped, plus any service-point warnings.
     * @throws AuraHandledException on any failure, with a fixed generic message. Nothing is
     *         committed when this throws - the service rolls back to a savepoint first.
     */
    @AuraEnabled
    public static MeterCaptureService.CaptureResult saveMeters(
            Id propertyAssetId, List<MeterCaptureService.MeterRow> rows) {
        try {
            return MeterCaptureService.save(propertyAssetId, rows);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'UtilityMeterController.saveMeters on '
                + propertyAssetId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(SAVE_FAILURE_MESSAGE);
        }
    }
}
