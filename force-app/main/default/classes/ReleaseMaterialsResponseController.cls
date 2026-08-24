/**
 * The `@AuraEnabled` boundary for the Release Materials response logger — backs
 * `c/releaseMaterialsResponseLog`, which `c/dispositionMain` renders at the `Release Materials`
 * disposition stage. Added 2026-08-24.
 *
 * Layering: THIN controller (ARCHITECTURE.md §2, `layer=controller`) — marshal, delegate, catch,
 * throw `AuraHandledException` with a user-safe message. **ZERO SOQL and ZERO DML of its own** and
 * zero business logic: the broker resolution, the method allow-list, the notes handling, the
 * `USER_MODE` insert and the ordering all live in `ReleaseMaterialsResponseService`.
 *
 * ── THE TWO-CLAUSE CATCH, AND WHY BOTH CLAUSES ARE REACHABLE ────────────────────────────────
 * `saveResponse` catches the service's typed exception FIRST and surfaces its message VERBATIM —
 * those are authored, user-safe sentences naming a mistake the user can fix ("Pick how this
 * response arrived: ..."). Everything else gets a FIXED generic message with no platform detail
 * concatenated into it, because raw `DmlException` text leaks field API names and validation-rule
 * internals. Same split, same reasons, as `CounterOfferController.saveCounterOffer`.
 * 🔴 BOTH CLAUSES ARE GENUINELY REACHABLE AND EACH HAS ITS OWN TEST. That is not a nicety: this
 * repo has a measured incident where a second, UNREACHABLE typed catch on a thin controller dropped
 * the class to 38% coverage and rolled back a deploy with every error counter reading zero. If a
 * future change makes the service incapable of throwing one of these, DELETE that clause rather
 * than leaving it for symmetry.
 *
 * ── ⚠ `getLogContext` IS `cacheable = true`, AND WHAT THAT COSTS ────────────────────────────
 * The card is read-once-per-page-view over data that changes only when someone clicks Save on this
 * same card — and that path calls `refreshApex`, so the staleness window is closed by the only
 * writer that exists. The one disagreement it can still produce is a broker appointed in ANOTHER
 * tab: this card would keep showing "no broker appointed yet" until a refresh. Benign, and the same
 * accepted trade `DispositionBuyerTimelineController` and `DispositionTractionController` document.
 * 🔴 `saveResponse` IS DELIBERATELY **NOT** CACHEABLE — a `cacheable = true` method may not perform
 * DML at all, and marking a write cacheable fails at runtime rather than at compile time.
 *
 * ── 🔴 A `QueryException` IS **NOT** SWALLOWED INTO AN EMPTY LOG ────────────────────────────
 * Every read behind this method is `WITH USER_MODE`, so a missing FLS or object grant THROWS rather
 * than degrading, and this controller turns that into a VISIBLE error. It deliberately does not
 * catch-and-return-empty: an empty log on a sale that has three recorded responses is a CONFIDENT
 * WRONG ANSWER that nothing else on the page contradicts, and a wrong answer nobody can detect is
 * worse than an error message that names the fix.
 * 🔴 THE FIX FOR SUCH AN ERROR IS A PERMISSION SET, NEVER `SYSTEM_MODE` ON THE SELECTOR —
 * ARCHITECTURE.md §2. The gates are enumerated in `ReleaseMaterialsResponseSelector`'s header.
 *
 * @see force-app/main/default/classes/ReleaseMaterialsResponseService.cls
 * @see force-app/main/default/lwc/releaseMaterialsResponseLog/releaseMaterialsResponseLog.js
 * @see force-app/main/default/classes/CounterOfferController.cls (the shape this copies)
 */
public with sharing class ReleaseMaterialsResponseController {

    /**
     * Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never interpolate
     * platform text or exception detail into it — the detail goes to the debug log (admin-only).
     */
    private static final String READ_FAILURE_MESSAGE =
        'The response log could not be loaded. Refresh the page or contact your administrator.';

    /** Fixed, generic user-safe message for an unexpected failed write. */
    private static final String WRITE_FAILURE_MESSAGE =
        'This response could not be logged. Refresh the page and try again, or contact your '
        + 'administrator.';

    /** An Id of the wrong SObject type is a wiring mistake, not a data state. See `getLogContext`. */
    private static final String WRONG_TYPE_MESSAGE =
        'The response log can only be read for a Disposition.';

    /**
     * `AuraHandledException` loses its message unless `setMessage` is called explicitly — a platform
     * quirk this repo hits everywhere, hence the helper.
     *
     * @param msg The user-safe message.
     * @return The exception, with its message actually set.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The whole logger card in one round trip: the resolved broker, whether this user may log, and
     * the responses already recorded (newest first).
     *
     * NOT-FOUND CONTRACT: a null Id returns a fully-populated EMPTY context — never null and never a
     * throw. The card's `@wire` fires before `recordId` is set on a slow first render.
     *
     * ── ⚠ A WRONG SOBJECT TYPE IS A DIFFERENT THING AND IS REFUSED ─────────────────────────────
     * Binding a foreign Id into `WHERE Disposition__c = :id` throws NOTHING — it simply matches no
     * rows. Without this guard a card wired to the wrong `record-id` would render a confident,
     * permanent empty log and nobody would learn it was pointed at the wrong record. The guard sits
     * OUTSIDE the try on purpose: inside it, the `catch (Exception)` below would swallow its own
     * `AuraHandledException` and replace this precise message with the generic one.
     *
     * @param dispositionId The Disposition whose response log to read; null-safe.
     * @return The context. Never null.
     * @throws AuraHandledException when the Id is of the wrong SObject type, or when the underlying
     *         read fails (almost always a missing FLS or object grant).
     */
    @AuraEnabled(cacheable=true)
    public static ReleaseMaterialsResponseService.LogContext getLogContext(Id dispositionId) {
        if (dispositionId != null && dispositionId.getSObjectType() != Disposition__c.SObjectType) {
            throw ahe(WRONG_TYPE_MESSAGE);
        }
        try {
            return ReleaseMaterialsResponseService.getLogContext(dispositionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'ReleaseMaterialsResponseController.getLogContext on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Logs one response against a Disposition.
     *
     * 🔴 THERE IS NO `brokerId` PARAMETER. The appointed broker is resolved server-side at save
     * time — see `ReleaseMaterialsResponseService`'s header. Adding one here would reopen exactly
     * the forgeable-attribution hole that design closes.
     *
     * Returns void: the component calls `refreshApex` on its `getLogContext` wire, so there is ONE
     * source of truth for the rendered list rather than a returned list that can disagree with the
     * cached one.
     *
     * @param dispositionId The parent sale; required.
     * @param method        `More questions`, `Decision` or `Offer`; required.
     * @param notes         Free-text detail; optional.
     * @throws AuraHandledException always, on failure: the service's authored message verbatim for a
     *         user-fixable input problem, and a fixed generic message for anything else.
     */
    @AuraEnabled
    public static void saveResponse(Id dispositionId, String method, String notes) {
        try {
            ReleaseMaterialsResponseService.logResponse(dispositionId, method, notes);
        } catch (ReleaseMaterialsResponseService.ReleaseMaterialsResponseException e) {
            // User-actionable input violation — surface the guidance verbatim.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'ReleaseMaterialsResponseController.saveResponse on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
