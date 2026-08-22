/**
 * Saves the meter register captured on the FSD UAT UT-001 screen: "meters saved against
 * property and spaces".
 *
 * ONE call, ONE transaction, at most TWO DML statements regardless of how many rows the
 * screen submits - the whole point of a capture GRID rather than a record-at-a-time form is
 * that a 60-suite property is one save, not sixty. There is no SOQL and no DML inside any
 * loop here; `MeterCaptureServiceTest` pins that with 251 rows.
 *
 * Layering (ARCHITECTURE.md section 2): all reads go through `MeterSelector` /
 * `UnitSelector`; this class owns the orchestration and the DML.
 *
 * === ACCESS: USER_MODE, ON PURPOSE, FOR BOTH THE READS AND THE WRITES ===
 * Every other access decision in this feature is an automation-path one, and several of
 * them escape FLS. This one must NOT. A person is sitting in front of this screen typing
 * meter numbers and utility account numbers into a Private-OWD object; if they lack create
 * or edit rights on `Meter__c`, the correct outcome is a refusal they can take to an admin,
 * not a silent elevated write. `USER_MODE` here throws, and that throw is the feature.
 *
 * === PARTIAL SAVES ARE NOT ALLOWED, AND THAT NEEDS A SAVEPOINT ===
 * The grid can produce both an insert list and an update list. `allOrNone = true` makes each
 * DML atomic on its own, but NOT the pair: an insert that succeeds followed by an update
 * that fails would leave half the grid committed and the screen showing an error, which is
 * the worst of both. The savepoint makes the pair atomic.
 */
public with sharing class MeterCaptureService {

    /**
     * One row of the capture grid. Lives on the SERVICE, not the controller, because it is
     * the service's input contract - the controller is a pass-through
     * (`DispositionService.InitiateOutcome` sets the same precedent).
     *
     * `meterId` null means CREATE; populated means UPDATE that existing meter. `unitId` null
     * means the meter serves the WHOLE BUILDING - FSD 5.10.4 makes that meaningful data, not
     * missing data, so it is never defaulted.
     */
    public class MeterRow {
        @AuraEnabled public Id meterId;
        @AuraEnabled public Id unitId;
        @AuraEnabled public String unitLabel;
        @AuraEnabled public String meterNumber;
        @AuraEnabled public String utilityType;
        @AuraEnabled public String utilityAccountNumber;
        @AuraEnabled public String serviceIdentifier;
        @AuraEnabled public String providerName;
        @AuraEnabled public String paidBy;
        @AuraEnabled public String paidByReason;
        @AuraEnabled public Decimal registerSize;
        @AuraEnabled public String serviceStatus;
    }

    /** What the save did, for the toast and for the screen's post-save refresh. */
    public class CaptureResult {
        @AuraEnabled public Integer created = 0;
        @AuraEnabled public Integer updated = 0;
        @AuraEnabled public Integer skipped = 0;
        @AuraEnabled public List<Id> meterIds = new List<Id>();
        /**
         * Non-fatal observations the user should see. Nothing here stops the save; the
         * records are already committed by the time these are read.
         */
        @AuraEnabled public List<String> warnings = new List<String>();
    }

    /** A row with none of these filled in is an untouched grid line, not an empty meter. */
    private static Boolean isBlank(MeterRow row) {
        return row == null
            || (String.isBlank(row.meterNumber)
                && String.isBlank(row.utilityType)
                && String.isBlank(row.utilityAccountNumber)
                && String.isBlank(row.serviceIdentifier)
                && row.registerSize == null);
    }

    /**
     * Creates and updates meters for one property in a single transaction.
     *
     * @param propertyAssetId The property every row belongs to. Required - a meter with no
     *                        property is invisible on every register list in the app, so a
     *                        null here is refused rather than silently accepted.
     * @param rows            The grid. Null/empty returns an empty result. Untouched lines
     *                        are counted in `skipped` and cost nothing.
     * @return What happened, including any ESID warnings.
     * @throws IllegalArgumentException when `propertyAssetId` is null.
     * @throws DmlException             when the running user may not create or edit
     *                                  `Meter__c`, or a row is invalid. Nothing is committed.
     */
    public static CaptureResult save(Id propertyAssetId, List<MeterRow> rows) {
        if (propertyAssetId == null) {
            throw new IllegalArgumentException(
                'A property is required before meters can be captured.');
        }
        CaptureResult result = new CaptureResult();
        if (rows == null || rows.isEmpty()) {
            return result;
        }

        List<Meter__c> toInsert = new List<Meter__c>();
        List<Meter__c> toUpdate = new List<Meter__c>();
        Set<String> serviceIdentifiers = new Set<String>();

        for (MeterRow row : rows) {
            if (isBlank(row)) {
                result.skipped++;
                continue;
            }
            Meter__c meter = toMeter(propertyAssetId, row);
            if (row.meterId == null) {
                toInsert.add(meter);
            } else {
                toUpdate.add(meter);
            }
            if (String.isNotBlank(row.serviceIdentifier)) {
                serviceIdentifiers.add(row.serviceIdentifier.trim());
            }
        }
        if (toInsert.isEmpty() && toUpdate.isEmpty()) {
            return result;
        }

        // Read BEFORE the write, so an ESID typed on this screen is compared against what
        // was already on the register rather than against itself.
        List<String> esidWarnings = detectServicePointReuse(serviceIdentifiers, rows);

        Savepoint sp = Database.setSavepoint();
        try {
            if (!toInsert.isEmpty()) {
                Database.insert(toInsert, true, AccessLevel.USER_MODE);
                result.created = toInsert.size();
            }
            if (!toUpdate.isEmpty()) {
                Database.update(toUpdate, true, AccessLevel.USER_MODE);
                result.updated = toUpdate.size();
            }
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }

        for (Meter__c m : toInsert) {
            result.meterIds.add(m.Id);
        }
        for (Meter__c m : toUpdate) {
            result.meterIds.add(m.Id);
        }
        result.warnings.addAll(esidWarnings);
        return result;
    }

    /** Maps one grid row onto a `Meter__c`, trimming text and normalising blanks to null. */
    private static Meter__c toMeter(Id propertyAssetId, MeterRow row) {
        return new Meter__c(
            Id = row.meterId,
            Property_Asset__c = propertyAssetId,
            Unit__c = row.unitId,
            Meter_Number__c = trimToNull(row.meterNumber),
            Utility_Type__c = trimToNull(row.utilityType),
            Utility_Account_Number__c = trimToNull(row.utilityAccountNumber),
            Service_Identifier__c = trimToNull(row.serviceIdentifier),
            Provider_Name__c = trimToNull(row.providerName),
            Paid_By__c = trimToNull(row.paidBy),
            Paid_By_Reason__c = trimToNull(row.paidByReason),
            Register_Size__c = row.registerSize,
            Service_Status__c = trimToNull(row.serviceStatus)
        );
    }

    private static String trimToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    /**
     * Flags a service identifier that is already on the register under a DIFFERENT meter
     * number - the signature of a physical meter swap on the same service point.
     *
     * FSD 5.10.4 defines the service identifier (the ESID on a Texas electricity account) as
     * the durable service-point id that SURVIVES a meter swap, while the meter number does
     * not. That makes this comparison the earliest point in the whole feature at which a
     * swap can be named: at capture time, by the person doing the typing, months before a
     * bill arrives with readings that go backwards and force
     * `UtilityBillDomain` to refuse a consumption figure.
     *
     * It is a WARNING and never a refusal. Two meters legitimately share an ESID during a
     * changeover, and FSD 5.10 asks for no validation rules. The value is in saying it out
     * loud while someone is looking.
     *
     * @param serviceIdentifiers ESIDs present in this save; empty short-circuits the query.
     * @param rows               The grid, re-scanned to compare meter numbers.
     * @return User-facing warning strings; never null.
     */
    private static List<String> detectServicePointReuse(Set<String> serviceIdentifiers,
            List<MeterRow> rows) {
        List<String> warnings = new List<String>();
        if (serviceIdentifiers.isEmpty()) {
            return warnings;
        }
        Map<String, Set<String>> existingNumbersByEsid = new Map<String, Set<String>>();
        Map<String, Set<Id>> existingIdsByEsid = new Map<String, Set<Id>>();
        for (Meter__c existing : MeterSelector.selectByServiceIdentifiers(serviceIdentifiers)) {
            String esid = existing.Service_Identifier__c;
            if (!existingNumbersByEsid.containsKey(esid)) {
                existingNumbersByEsid.put(esid, new Set<String>());
                existingIdsByEsid.put(esid, new Set<Id>());
            }
            existingIdsByEsid.get(esid).add(existing.Id);
            if (String.isNotBlank(existing.Meter_Number__c)) {
                existingNumbersByEsid.get(esid).add(existing.Meter_Number__c);
            }
        }
        for (MeterRow row : rows) {
            if (isBlank(row) || String.isBlank(row.serviceIdentifier)) {
                continue;
            }
            String esid = row.serviceIdentifier.trim();
            Set<String> numbers = existingNumbersByEsid.get(esid);
            if (numbers == null || numbers.isEmpty()) {
                continue;
            }
            // Editing the meter that already owns this ESID is not a swap.
            Set<Id> owners = existingIdsByEsid.get(esid);
            if (row.meterId != null && owners.contains(row.meterId) && owners.size() == 1) {
                continue;
            }
            if (String.isNotBlank(row.meterNumber) && numbers.contains(row.meterNumber.trim())) {
                continue;
            }
            warnings.add('Service identifier ' + esid
                + ' is already on the register under meter number '
                + String.join(new List<String>(numbers), ', ')
                + '. If the meter was physically replaced, readings will not be comparable '
                + 'across the change.');
        }
        return warnings;
    }
}
