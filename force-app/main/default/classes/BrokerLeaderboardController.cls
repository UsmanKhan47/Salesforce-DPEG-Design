/**
 * The `@AuraEnabled` boundary for the broker leaderboard — backs `lwc/brokerLeaderboard`
 * on the Acquisitions Broker Hub. FSD §27.3 / §27.4, tranche 3 item 2.
 *
 * Layering: thin controller (ARCHITECTURE.md §2) — marshal, delegate, catch, throw
 * `AuraHandledException` with a fixed user-safe message. **Zero SOQL of its own**; all
 * reads are `BrokerLeaderboardService` -> `CompetingBrokerSubmissionSelector`.
 *
 * ⚠ THE ONLY PARAMETER IS A DEPTH, AND IT IS CLAMPED SERVER-SIDE. The method takes no
 * filter, no broker key and no ordering choice, so an `@AuraEnabled` method invoked
 * directly cannot use it to interrogate the ledger in ways the page cannot — the worst a
 * hand-crafted call achieves is a longer list of the same public ranking.
 * `BrokerLeaderboardService.MAX_ROWS_CEILING` bounds it.
 *
 * ⚠ `cacheable=true` — READ-ONLY, AND THE STALENESS IS ACCEPTABLE HERE. This is a ranking
 * over an append-only audit ledger; a broker's position changing one page-view late has no
 * consequence, and nothing on this page writes to `Competing_Broker_Submission__c`
 * (`PropertyClaimService` writes it from an async pipeline, never from this UI). Contrast
 * `DispositionTractionController`, whose header records a real staleness hazard because a
 * sibling component on the same page WRITES the data it reads.
 *
 * ⚠ WHAT THIS CONTROLLER DELIBERATELY DOES NOT EXPOSE: a drill-through to a broker's
 * submissions. That read must consult BOTH winner anchors (`Winning_Lead__c` AND
 * `Winning_Opportunity__c`), and the existing
 * `CompetingBrokerSubmissionSelector.selectByWinningLead` is Lead-only — ARCHITECTURE.md's
 * named open gap. Adding a row action here without closing that gap would render a
 * converted winner's trail as empty, which reads as "this broker has submitted nothing"
 * on precisely the deals that went furthest. See `BrokerLeaderboardService`'s header.
 *
 * @see BrokerLeaderboardService.cls
 * @see force-app/main/default/lwc/brokerLeaderboard/brokerLeaderboard.js
 */
public with sharing class BrokerLeaderboardController {

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never
    // interpolate platform text or exception detail into it — the detail goes to the debug
    // log (admin-only) and the user gets this. Matches BrokerController's shape so the two
    // Broker Hub components fail with one voice.
    private static final String READ_FAILURE_MESSAGE =
        'The broker leaderboard could not be loaded. Refresh the page or contact your administrator.';

    /**
     * Build an AuraHandledException whose message actually reaches the client.
     * `setMessage` is required — the constructor alone yields "Script-thrown exception".
     *
     * @param msg The user-safe message.
     * @return The exception to throw.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The leaderboard, busiest broker first.
     *
     * @param maxRows How many rows to return. Null falls back to
     *                `BrokerLeaderboardService.DEFAULT_MAX_ROWS`; the service clamps
     *                anything above `MAX_ROWS_CEILING` and returns empty for &lt; 1.
     * @return Ranked broker rows; an empty list when the ledger holds no submission with a
     *         broker email (an empty leaderboard is normal on a fresh org, not an error).
     * @throws AuraHandledException with a fixed user-safe message on any read failure.
     */
    @AuraEnabled(cacheable=true)
    public static List<BrokerLeaderboardService.BrokerRow> getLeaderboard(Integer maxRows) {
        try {
            Integer depth = (maxRows == null) ? BrokerLeaderboardService.DEFAULT_MAX_ROWS : maxRows;
            return BrokerLeaderboardService.leaderboard(depth);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerLeaderboardController.getLeaderboard: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
