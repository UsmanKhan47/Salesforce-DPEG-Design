/**
 * The `@AuraEnabled` boundary for the two call-for-offers surfaces: `lwc/callForOffersList` (the
 * Lead Funnel table) and `lwc/callForOffersPanel` (the Opportunity record page).
 *
 * ── ONE CONTROLLER, TWO METHODS, AND WHY NOT TWO CONTROLLERS ────────────────
 * Both surfaces render the SAME derivation from the SAME service, differing only in whether they
 * ask about every deal or one. Splitting them would double the class-access grants a permission set
 * has to carry and would invite the two to drift into two shapes of DTO. `OpportunityFunnelController`
 * is the in-repo precedent for several read methods behind one controller.
 *
 * ⚠ THE COROLLARY, BECAUSE APEX CLASS ACCESS IS PER-CLASS AND NOT PER-METHOD: a persona that may
 * see EITHER surface can invoke BOTH. That is acceptable here and would not be if one of them were
 * a write — both methods are `cacheable=true` reads returning the same shape, gated by the same
 * `WITH USER_MODE` selector, so there is no capability in one that the other does not already have.
 *
 * Layering: thin controller (ARCHITECTURE.md §2) — marshal, delegate, catch, throw
 * `AuraHandledException` with a fixed user-safe message. Zero SOQL, zero DML, zero business logic.
 * Every threshold lives in `CallForOffersService`.
 *
 * ── ⚠ `cacheable=true` MEANS THE COUNTDOWN CAN BE STALE ON THE CLIENT ───────
 * Both methods are cacheable, so the client holds the payload and nothing here invalidates it. The
 * exposure is bounded and much smaller than the `DispositionTractionController` case it otherwise
 * resembles: the value changes at most once per day (it is a day count), there is no in-page action
 * that can change a due date, and a page reload always shows the truth. Cacheable is KEPT — the
 * alternative is a server round trip on every render of a value with a 24-hour shelf life. If a
 * component is ever added that EDITS `Offer_Due_Date__c` on the same page, `refreshApex` on the
 * retained wire result is the tool, NOT `getRecordNotifyChange`: the countdown is an Apex
 * computation, not a field on the record.
 *
 * ── ⚠ A MEASURED COVERAGE NOTE ON THE `catch` BLOCKS ────────────────────────
 * Unlike `DispositionTractionController`, these catches ARE reachable from a test: both reads are
 * `WITH USER_MODE`, so `System.runAs` a bare user (no permission sets, hence no FLS on
 * `Offer_Due_Date__c`) makes the selector throw `QueryException` and the catch runs. That is the
 * repo-standard technique and both tests use it. Do not "simplify" either read to `SYSTEM_MODE` —
 * beyond being wrong for a user-requested read, it would make these catches untestable.
 *
 * @see force-app/main/default/classes/CallForOffersService.cls
 * @see force-app/main/default/lwc/callForOffersList/callForOffersList.js
 * @see force-app/main/default/lwc/callForOffersPanel/callForOffersPanel.js
 */
public with sharing class CallForOffersController {

    // Fixed, generic user-safe messages (ARCHITECTURE.md §5). NEVER interpolate platform text or
    // exception detail into them — the detail goes to the debug log, which is admin-only.
    private static final String LIST_FAILURE_MESSAGE =
        'Call for offers could not be loaded. Refresh the page or contact your administrator.';

    private static final String PANEL_FAILURE_MESSAGE =
        'The offer deadline could not be loaded. Refresh the page or contact your administrator.';

    /** An Id of the wrong SObject type is a wiring mistake, not a data state. See `getForOpportunity`. */
    private static final String WRONG_TYPE_MESSAGE =
        'Offer deadlines can only be read for an Opportunity.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * Every open deal with a call-for-offers due date, soonest deadline first — the Lead Funnel
     * table.
     *
     * EMPTY CONTRACT: an empty list is a normal, meaningful answer ("no live call-for-offers
     * deadlines"), never an error. The component renders its own empty state for it.
     *
     * @return Computed states, soonest deadline first. Never null.
     */
    @AuraEnabled(cacheable=true)
    public static List<CallForOffersService.CallForOffers> getUpcoming() {
        try {
            return CallForOffersService.upcoming();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'CallForOffersController.getUpcoming: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(LIST_FAILURE_MESSAGE);
        }
    }

    /**
     * One deal's call-for-offers state — the Opportunity record-page panel.
     *
     * NOT-FOUND CONTRACT: a null Id, or an Id that resolves to no readable row, returns the
     * `NO_DUE_DATE` state rather than null or an exception. "This deal has no offer deadline" is a
     * true and useful answer; a null would render an empty box indistinguishable from a failure.
     *
     * ── ⚠ A WRONG SOBJECT TYPE IS A DIFFERENT THING AND IS REFUSED ─────────
     * An Id of some other object is a WIRING MISTAKE (the component dropped on the wrong record
     * page), not a data state, and it is refused rather than folded into `NO_DUE_DATE`. Without the
     * guard, a mis-wired panel would render a confident, permanently green "No offer deadline" and
     * nobody would ever learn it was pointed at the wrong record — the failure
     * `DispositionTractionController` measured and guards against for the same reason. The guard
     * sits OUTSIDE the try on purpose: inside it, the `catch (Exception)` below would swallow its
     * own `AuraHandledException` and replace a precise message with the generic one.
     *
     * @param opportunityId The deal to evaluate.
     * @return Its computed state. Never null.
     */
    @AuraEnabled(cacheable=true)
    public static CallForOffersService.CallForOffers getForOpportunity(Id opportunityId) {
        if (opportunityId != null && opportunityId.getSObjectType() != Opportunity.SObjectType) {
            throw ahe(WRONG_TYPE_MESSAGE);
        }
        try {
            return CallForOffersService.forOpportunity(opportunityId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'CallForOffersController.getForOpportunity on '
                + opportunityId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(PANEL_FAILURE_MESSAGE);
        }
    }
}
