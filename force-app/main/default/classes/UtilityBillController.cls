/**
 * Backs `c/utilityBillDetail` - the Utility Bill record-page panel that shows the charge
 * components and the FSD 5.10.5 variance decomposition.
 *
 * THIN by contract (`.claude/rules/apex-layering-rule.md`): no SOQL, no DML, no arithmetic
 * beyond the one derived percentage explained below. Reads go to `UtilityBillSelector` and
 * `ChargeLineSelector`.
 *
 * ERROR BOUNDARY (ARCHITECTURE.md section 5): failures become an `AuraHandledException` with
 * a fixed generic message; platform detail goes to the admin-only debug log. Same shape as
 * `WorkOrderController` lines 16-23.
 *
 * ============================================================================
 * WHY THE PERCENTAGE IS COMPUTED HERE INSTEAD OF READ FROM THE FIELD
 * ============================================================================
 * `Utility_Bill__c.Total_Variance_Pct__c` exists, and this class deliberately does not use
 * it, because the deployed formula is WRONG BY A FACTOR OF 100.
 *
 * Measured against `usman-dpeg` on 2026-08-22, twice, in isolation:
 *   prior total 100.00, current total 200.00  -> a 100% rise
 *   Total_Variance_Pct__c returned            -> 10000.00
 *   prior total 200.00, current total 345.00  -> a 72.5% rise
 *   Total_Variance_Pct__c returned            -> 7250.00
 *
 * The formula ends in `* 100`, and its own field comment asserts that "a Percent FORMULA
 * field displays the raw result with a percent sign; it does not multiply by 100... removing
 * it would silently render every variance as a hundredth of its real value." The measurement
 * says the opposite: the platform scales a Percent formula result for display, so the `* 100`
 * is applied twice. THE FIELD COMMENT IS THE DEFECT - it argues convincingly for the bug.
 *
 * This build cannot fix it: field metadata is out of scope here. So this controller derives
 * the figure from the two totals it is already holding, which costs nothing and cannot be
 * wrong. When the formula is corrected (drop the `* 100`), `variancePct` and the field will
 * agree and either may be used.
 *
 * DO NOT "simplify" this method away to a field read until that deploy has happened AND been
 * re-measured. A 20% threshold read against the current field fires at 0.2%.
 * ============================================================================
 */
public with sharing class UtilityBillController {

    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';

    /**
     * Shown when `Consumption__c` is blank while both readings are present and the current
     * reading is LOWER than the previous one.
     *
     * It names both possibilities rather than guessing between them, because that is the
     * honest state of the evidence: `UtilityBillDomain` refused precisely BECAUSE it could
     * not tell a register rollover from a meter swap. Telling the user which one it "thinks"
     * it is would re-introduce the guess the domain declined to make.
     */
    @TestVisible
    private static final String UNRESOLVED_CONSUMPTION_MESSAGE =
        'Consumption was not calculated: this bill\'s current reading is lower than its '
        + 'previous reading. That is either a register rollover or a meter swap, and the two '
        + 'are identical on the invoice. Check the meter number on the invoice against the '
        + 'register, then enter Consumption manually if the meter was replaced.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /** One charge component of a bill (FSD 5.10.3). */
    public class ChargeRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String chargeType;
        @AuraEnabled public Decimal amount;
        /** This component's share of the bill total, 0-100. Null when the total is 0. */
        @AuraEnabled public Decimal sharePct;
    }

    /** The bill, its components, and the variance decomposition. */
    public class BillDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id meterId;
        @AuraEnabled public String meterNumber;
        @AuraEnabled public String utilityType;
        @AuraEnabled public String serviceIdentifier;
        @AuraEnabled public String propertyName;
        @AuraEnabled public String unitLabel;
        @AuraEnabled public Date billDate;
        @AuraEnabled public Date readDate;
        @AuraEnabled public Decimal previousReading;
        @AuraEnabled public Decimal currentReading;
        @AuraEnabled public Decimal consumption;
        @AuraEnabled public Decimal totalCharges;
        @AuraEnabled public Decimal ratePerUnit;

        // ---- prior bill, the anchor every variance figure is measured against ----
        @AuraEnabled public Id priorBillId;
        @AuraEnabled public String priorBillName;
        @AuraEnabled public Date priorReadDate;
        @AuraEnabled public Decimal priorConsumption;
        @AuraEnabled public Decimal priorTotalCharges;
        @AuraEnabled public Decimal priorRatePerUnit;

        // ---- FSD 5.10.5 decomposition ----
        /** Change in consumption valued at the PRIOR unit rate. */
        @AuraEnabled public Decimal usageVariance;
        /** Change in unit rate valued at the CURRENT consumption. */
        @AuraEnabled public Decimal rateVariance;
        /** The raw dollar change. Usage + rate reconciles to this exactly. */
        @AuraEnabled public Decimal totalVariance;
        /** Derived here, not read from the field. See the class header. */
        @AuraEnabled public Decimal totalVariancePct;
        /** True when there is no prior bill, so no variance exists to show. */
        @AuraEnabled public Boolean hasPrior;

        @AuraEnabled public List<ChargeRow> chargeLines = new List<ChargeRow>();
        /** Non-null when consumption could not be computed - see the constant above. */
        @AuraEnabled public String consumptionWarning;
    }

    /**
     * The full detail for one bill: two queries, one for the bill and one for its charge
     * lines.
     *
     * @param billId The bill being viewed.
     * @return The detail, or null when the bill does not exist or is not visible to the
     *         running user. A null return lets the component render its own empty state
     *         rather than an error, which is the right treatment for "you cannot see this".
     * @throws AuraHandledException on any read failure, with a fixed generic message.
     */
    @AuraEnabled(cacheable=true)
    public static BillDetail getBillDetail(Id billId) {
        try {
            Utility_Bill__c bill = UtilityBillSelector.selectDetailById(billId);
            if (bill == null) {
                return null;
            }
            BillDetail d = new BillDetail();
            d.id = bill.Id;
            d.name = bill.Name;
            d.meterId = bill.Meter__c;
            d.meterNumber = bill.Meter__r == null ? null : bill.Meter__r.Meter_Number__c;
            d.utilityType = bill.Meter__r == null ? null : bill.Meter__r.Utility_Type__c;
            d.serviceIdentifier =
                bill.Meter__r == null ? null : bill.Meter__r.Service_Identifier__c;
            d.propertyName = (bill.Meter__r == null || bill.Meter__r.Property_Asset__r == null)
                ? null
                : bill.Meter__r.Property_Asset__r.Property_Name__c;
            d.unitLabel = (bill.Meter__r == null || bill.Meter__r.Unit__r == null)
                ? 'Whole building'
                : bill.Meter__r.Unit__r.Suite_Number__c;
            d.billDate = bill.Bill_Date__c;
            d.readDate = bill.Read_Date__c;
            d.previousReading = bill.Previous_Reading__c;
            d.currentReading = bill.Current_Reading__c;
            d.consumption = bill.Consumption__c;
            d.totalCharges = bill.Total_Charges_Amount__c;
            d.ratePerUnit = bill.Rate_Per_Unit__c;

            d.hasPrior = bill.Prior_Utility_Bill__c != null;
            if (d.hasPrior) {
                d.priorBillId = bill.Prior_Utility_Bill__c;
                d.priorBillName = bill.Prior_Utility_Bill__r.Name;
                d.priorReadDate = bill.Prior_Utility_Bill__r.Read_Date__c;
                d.priorConsumption = bill.Prior_Utility_Bill__r.Consumption__c;
                d.priorTotalCharges = bill.Prior_Utility_Bill__r.Total_Charges_Amount__c;
                d.priorRatePerUnit =
                    unitRate(d.priorTotalCharges, d.priorConsumption);
                d.usageVariance = bill.Usage_Variance_Amount__c;
                d.rateVariance = bill.Rate_Variance_Amount__c;
                d.totalVariance = bill.Total_Variance_Amount__c;
                d.totalVariancePct = variancePct(d.totalCharges, d.priorTotalCharges);
            }

            if (isConsumptionUnresolved(bill)) {
                d.consumptionWarning = UNRESOLVED_CONSUMPTION_MESSAGE;
            }

            for (Charge_Line__c line :
                    ChargeLineSelector.selectByBillIds(new Set<Id>{ bill.Id })) {
                ChargeRow row = new ChargeRow();
                row.id = line.Id;
                row.chargeType = String.isBlank(line.Charge_Type__c)
                    ? 'Unclassified'
                    : line.Charge_Type__c;
                row.amount = line.Charge_Amount__c;
                row.sharePct = share(line.Charge_Amount__c, d.totalCharges);
                d.chargeLines.add(row);
            }
            return d;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'UtilityBillController.getBillDetail on '
                + billId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Percentage change of `current` against `prior`, on the scale a human reads: a rise
     * from 100 to 200 returns 100, not 1 and not 10000.
     *
     * Null when there is no prior figure or it is zero - a percentage change FROM zero has
     * no meaning, and returning 100 (or infinity, or 0) for it would put a fabricated number
     * in front of the monthly review and, worse, past an alert threshold.
     *
     * Public and static because `UtilityMeterController` needs the identical arithmetic for
     * the register list and `UtilityVarianceAlertBatch` for its threshold - one
     * implementation, so the list, the record page and the alert can never disagree about
     * the same bill. See the class header for why this exists at all.
     *
     * @param current Current total charges.
     * @param prior   Prior total charges.
     * @return The percentage change, or null when it is undefined.
     */
    public static Decimal variancePct(Decimal current, Decimal prior) {
        if (prior == null || prior == 0 || current == null) {
            return null;
        }
        return ((current - prior) / prior * 100).setScale(2, System.RoundingMode.HALF_UP);
    }

    /** Blended unit rate, or null when consumption is zero/absent (the rate is undefined). */
    private static Decimal unitRate(Decimal totalCharges, Decimal consumption) {
        if (totalCharges == null || consumption == null || consumption == 0) {
            return null;
        }
        return (totalCharges / consumption).setScale(4, System.RoundingMode.HALF_UP);
    }

    /** One component's share of the bill total, or null when the total is zero/absent. */
    private static Decimal share(Decimal amount, Decimal total) {
        if (amount == null || total == null || total == 0) {
            return null;
        }
        return (amount / total * 100).setScale(1, System.RoundingMode.HALF_UP);
    }

    /**
     * Whether this bill's consumption was REFUSED rather than merely not yet entered.
     *
     * The signature is specific: both readings present, the current one lower, and
     * `Consumption__c` blank. That is exactly the state `UtilityBillDomain` leaves behind
     * when it declines to guess between a rollover and a meter swap. A blank consumption
     * with no readings at all is just an unfinished record and gets no warning.
     */
    @TestVisible
    private static Boolean isConsumptionUnresolved(Utility_Bill__c bill) {
        return bill.Consumption__c == null
            && bill.Previous_Reading__c != null
            && bill.Current_Reading__c != null
            && bill.Current_Reading__c < bill.Previous_Reading__c;
    }
}
