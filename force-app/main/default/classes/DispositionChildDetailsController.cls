/**
 * Resolves the Id of the "primary" child record of one Disposition, for the generic
 * `c/dispositionChildDetails` LWC that renders that child's OWN fields, read-only, inside the
 * Disposition record page's Details slot at the LOI and PSA stages.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * WHY THIS CLASS EXISTS AT ALL — AND WHY IT IS NOT THE NDA-STAGE PATTERN
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * The NDA-stage Details section on `Disposition_Record_Page` shows NDA fields WITHOUT any Apex:
 * `Disposition__c` carries `Primary_NDA__c`, and a set of `NDA_*__c` FORMULA fields traverse it,
 * so the FlexiPage can reference them as ordinary `Record.` fields.
 *
 * 🔴 THERE IS NO `Primary_LOI__c` AND NO `Primary_PSA__c` ON `Disposition__c` — verified against
 * `objects/Disposition__c/fields/` on 2026-08-25, not assumed. Reproducing the NDA route for LOI
 * and PSA would mean: two new lookups, a stamping queueable to populate them, a backfill over
 * every existing sale, and nine more formula fields. That is a schema-and-automation change to
 * show nine fields nobody edits here. This controller plus one small LWC is the cheaper half of
 * that trade, and it is REVERSIBLE — if the lookups are ever added for another reason, the two
 * FlexiPage itemInstances become fieldSections and this class is deleted.
 *
 * ── LAYER: controller (`.claude/rules/apex-layering-rule.md`) ────────────────────────────────
 * Thin by construction: NO SOQL of its own, no business logic. It validates its two arguments and
 * delegates to the matching selector. There is deliberately no Service class between the two —
 * there is no orchestration to put in one; a service here would be a pass-through with a longer
 * name.
 *
 * ── FLS/SHARING: `with sharing`, and the selectors it calls are `WITH USER_MODE` ─────────────
 * `LoiSelector.selectLatestByDispositionId` and
 * `ContractReviewSelector.selectLatestByDispositionId` are BOTH already `WITH USER_MODE` — read
 * their headers; each records that USER_MODE is correct precisely because a human asked for the
 * read by opening the record page (ARCHITECTURE.md §2). That is exactly this call site, so they
 * are reused verbatim and NO new selector method was added.
 *
 * ⚠ THE PRICE OF THAT REUSE, RECORDED SO A LATER FLS CHANGE IS DIAGNOSABLE. `WITH USER_MODE`
 * enforces FLS on every field in the SELECT list, not just the ones the caller consumes, and it
 * THROWS (`QueryException: No such column`) rather than degrading. This class consumes only `Id`,
 * but the two selector methods also select `LOI__c.Stage__c / Offer_Price__c / Ball_In_Court__c`
 * and `Contract_Review__c.Negotiation_Status__c / Execution_Date__c / Latest_Version__c`. Both
 * selectors' headers record all of those as granted in `DPEG_Disposition_View` and
 * `DPEG_Disposition_Edit` as of 2026-08-20. If read on ANY of them is ever revoked, this card
 * fails with the generic read-failure message below and the fix is the permission set, NOT this
 * class. Adding an Id-only selector method would decouple them; that was weighed and rejected
 * here only because it would drag two well-covered selector classes into this deploy.
 *
 * 🔴 THE EMPTY STATE AND THE FAILURE STATE ARE DELIBERATELY DIFFERENT ANSWERS. `null` means "this
 * sale genuinely has no LOI/PSA yet" and the LWC says so in one honest line. A denied or broken
 * read throws `AuraHandledException` and the LWC shows an error. Collapsing the second into the
 * first — the obvious "fail soft, return null" shortcut — would tell a user that a document they
 * negotiated does not exist. That is the one wrong answer this surface can give.
 *
 * ⚠ REGISTERED IN `permissionsets/DPEG_Apex_Access.permissionset-meta.xml`. An `@AuraEnabled`
 * entry-point class that is not listed there fails at runtime with "You do not have access to the
 * Apex class named ..." — three live breaks in this repo from exactly that omission, the most
 * recent documented in that file's own header comment.
 *
 * @see c/dispositionChildDetails
 * @see LoiSelector
 * @see ContractReviewSelector
 */
public with sharing class DispositionChildDetailsController {
    /**
     * The child objects this controller will resolve. ALL_CAPS_SNAKE_CASE per the project Apex
     * standard. An enum rather than bare string comparison so an unrecognised `childObject`
     * argument is a single lookup miss with one refusal path, not a chain of `equals` calls.
     */
    public enum DISPOSITION_CHILD {
        LOI,
        CONTRACT_REVIEW
    }

    /**
     * API name → enum. This map IS the allow-list: anything not a key here is refused, so the
     * `childObject` design attribute cannot be pointed at an arbitrary object from App Builder.
     *
     * 🔴 THE KEYS ARE LOWER-CASE AND THE LOOKUP LOWER-CASES ITS ARGUMENT. That is not tidiness,
     * it is a correction: an earlier version of this class keyed the map on the real API names and
     * its own comment asserted that "Apex `Map<String, ...>.get` is case-insensitive". IT IS NOT —
     * measured by a check-only deploy on usman-dpeg 2026-08-25, where `get('loi__c')` returned
     * null and the card took the refusal path. The confusion is real and worth recording: Apex
     * `==` / `!=` ON String IS case-INSENSITIVE, while a String-keyed Map's `get`/`containsKey`
     * are case-SENSITIVE. Two different answers from the same type, and only the map is strict.
     *
     * Tolerating case matters here because the failure is silent and permanent: `childObject`
     * comes from a FlexiPage design-time property, so a hand-edited page carrying `loi__c` would
     * render an error card on every LOI-stage sale with nothing in a log to explain it.
     */
    private static final Map<String, DISPOSITION_CHILD> CHILD_BY_LOWER_API_NAME =
        new Map<String, DISPOSITION_CHILD>{
            'loi__c' => DISPOSITION_CHILD.LOI,
            'contract_review__c' => DISPOSITION_CHILD.CONTRACT_REVIEW
        };

    /** Generic, user-safe read-failure text (ARCHITECTURE.md §5). Never interpolate platform
     *  detail into it — the detail goes to the debug log, the user gets this. */
    private static final String READ_FAILURE_MESSAGE =
        'This section could not be loaded. Refresh the page or contact your administrator.';

    /** Wiring mistake, not a permission gap — so it must NOT read like READ_FAILURE_MESSAGE. */
    private static final String WRONG_PARENT_MESSAGE =
        'This section can only be read for a Disposition.';

    /** Also a wiring mistake: the component was configured with an object it cannot resolve. */
    private static final String UNSUPPORTED_CHILD_MESSAGE =
        'Unsupported child object. Expected LOI__c or Contract_Review__c.';

    /**
     * `new AuraHandledException(msg)` alone leaves `getMessage()` as "Script-thrown exception";
     * `setMessage` is what makes the text reach the browser AND makes it assertable in a test.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The Id of the most recently created LOI__c / Contract_Review__c under one Disposition.
     *
     * "Most recent" is `ORDER BY CreatedDate DESC, Id DESC LIMIT 1`, defined in the two selector
     * methods — the `Id DESC` tie-break matters because `CreatedDate` is second-granular and two
     * children created in the same second would otherwise make this card flip between refreshes.
     *
     * ⚠ BOTH GUARDS ARE OUTSIDE THE `try` ON PURPOSE. A configuration mistake must surface as
     * itself; inside the try it would be caught and re-thrown as the generic read failure, which
     * sends whoever debugs it to the permission sets instead of to the FlexiPage.
     *
     * ⚠ ONE `catch (Exception)`, NOT a typed pair. A second, narrower catch on this thin a method
     * is unreachable in test and shows up as an uncoverable branch that fails a production deploy
     * on the per-class 75% rule — measured in this repo, see `.claude/agent-memory-local`.
     *
     * @param dispositionId Parent Disposition Id. Null-safe: returns null, which the LWC renders
     *        as its ordinary empty state (a card can be dropped on a page before a record exists).
     * @param childObject   `LOI__c` or `Contract_Review__c`. Anything else is refused.
     * @return The child Id, or `null` when this Disposition has no such child yet.
     * @throws AuraHandledException on a foreign parent type, an unsupported child object, or any
     *         failure of the underlying read (including an FLS denial).
     * @example
     * Id loiId = DispositionChildDetailsController.getPrimaryChildId(dispositionId, 'LOI__c');
     */
    @AuraEnabled(cacheable=true)
    public static Id getPrimaryChildId(Id dispositionId, String childObject) {
        if (dispositionId != null
            && dispositionId.getSObjectType() != Disposition__c.SObjectType) {
            throw ahe(WRONG_PARENT_MESSAGE);
        }

        // String.isBlank is null-safe; toLowerCase() on a null String is not.
        DISPOSITION_CHILD child = String.isBlank(childObject)
            ? null
            : CHILD_BY_LOWER_API_NAME.get(childObject.trim().toLowerCase());
        if (child == null) {
            throw ahe(UNSUPPORTED_CHILD_MESSAGE);
        }

        // Return early: no parent, no child. Costs a query we would otherwise spend proving it.
        if (dispositionId == null) {
            return null;
        }

        try {
            if (child == DISPOSITION_CHILD.LOI) {
                LOI__c loi = LoiSelector.selectLatestByDispositionId(dispositionId);
                return loi == null ? null : loi.Id;
            }
            Contract_Review__c psa =
                ContractReviewSelector.selectLatestByDispositionId(dispositionId);
            return psa == null ? null : psa.Id;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                'DispositionChildDetailsController.getPrimaryChildId(' + dispositionId + ', '
                    + childObject + '): ' + e.getMessage() + ' | ' + e.getStackTraceString()
            );
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
