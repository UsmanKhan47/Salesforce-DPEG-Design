/**
 * FSD 5.9.7 ROWS 6 AND 7 - the two alerts that are neither feed-driven nor commitment-driven: a
 * follow-up that has gone stale, and a write-off waiting on a principal.
 *
 * LAYER - Service. Reads via `CaseSelector`, notifies via `GroupNotifier`, owns its own Case DML.
 * No inline SOQL.
 *
 * === WHY THESE LIVE HERE AND RUN FROM `finish()` ===
 * Both are driven by the passage of TIME and by Case state, not by tonight's feed. Running them per
 * chunk would re-query the same set for every chunk and would miss any Case whose tenant is absent
 * from the feed - which is exactly the population most likely to have been forgotten. They run once
 * per nightly run, from `ReceivablesSyncBatch.finish()`. FSD 5.9.6 describes ONE nightly job, so no
 * second schedulable is introduced.
 *
 * === THE STALE-FOLLOW-UP ALERT INTENTIONALLY HAS NO IDEMPOTENCY MARKER ===
 * Unlike the escalation ladder and the breach marker, this one is SUPPOSED to repeat. "No follow-up
 * in seven days" is a condition that persists until somebody acts, and silencing it after the first
 * night would turn the one alert designed to nag into another one that fires once and is missed. It
 * stops firing when the PM records a follow-up - i.e. when the condition ends - which is the correct
 * termination.
 * WARNING - THE FIELD IT KEYS ON IS NOT AUTO-STAMPED YET. `Case.Last_Follow_Up_DateTime__c` is
 * written by the sync and by humans, but no CaseComment trigger stamps it on comment creation. See
 * the handoff note in the stream report; until that exists, a PM who comments without touching the
 * field still looks stale.
 *
 * === THE WRITE-OFF ALERT REUSES THE ESCALATION LADDER AS ITS MARKER ===
 * Level 3 is the write-off rung: one-way, never re-fired, exactly like levels 1 and 2. A separate
 * `Write_Off_Notified__c` field would have been schema this stream is not permitted to add, and a
 * write-off genuinely IS the rung above 90 days rather than a parallel concept.
 *
 * @see DelinquencyCaseService.cls (which owns levels 0-2 and the constant LEVEL_WRITE_OFF)
 */
public with sharing class DelinquencyAlertService {

    @TestVisible private static final String GROUP_PM = 'DPEG_Property_Mgmt_Team';
    @TestVisible private static final String GROUP_PRINCIPALS = 'Principals';
    @TestVisible private static final String NOTIF_TYPE = 'Property_Mgmt_Update';
    @TestVisible private static final Integer LEVEL_WRITE_OFF = 3;
    @TestVisible private static final Integer MAX_ALERT_ROWS = 2000;

    /** What the alert sweep did. */
    public class AlertResult {
        /** Stale-follow-up reminders sent. */
        public Integer staleReminders = 0;
        /** Write-off requests routed to the principals for decision. */
        public Integer writeOffsRouted = 0;
    }

    /**
     * Run both date/state-driven alerts.
     *
     * @param asOf The date to measure staleness against, captured once by the caller.
     * @return Counters; never null.
     */
    public static AlertResult sweepAlerts(Date asOf) {
        AlertResult result = new AlertResult();
        if (asOf == null) {
            return result;
        }
        List<GroupNotifier.Request> requests = new List<GroupNotifier.Request>();

        // ── ROW 6: stale follow-up. Empty when unconfigured - no default, by design. ─────────────
        Integer staleDays = ReceivablesSyncConfig.staleFollowUpDays();
        for (Case staleCase : CaseSelector.selectStaleFollowUp(asOf, staleDays, MAX_ALERT_ROWS)) {
            requests.add(buildRequest(GROUP_PM, 'Delinquency follow-up overdue',
                'Case ' + staleCase.CaseNumber + ' has had no follow-up since '
                + String.valueOf(staleCase.Last_Follow_Up_DateTime__c)
                + '. Outstanding: ' + staleCase.Current_Balance_Amount__c + '.',
                staleCase.Id));
            result.staleReminders++;
        }

        // ── ROW 7: write-off awaiting a principal. Level 3 is the one-way marker. ────────────────
        List<Case> writeOffs = CaseSelector.selectWriteOffAwaitingDecision(MAX_ALERT_ROWS);
        List<Case> writeOffStamps = new List<Case>();
        List<Integer> stampIndexes = new List<Integer>();
        for (Case writeOffCase : writeOffs) {
            Decimal level = writeOffCase.Escalation_Level__c;
            if (level != null && level.intValue() >= LEVEL_WRITE_OFF) {
                continue; // already routed; never re-fire the same alert
            }
            stampIndexes.add(requests.size());
            requests.add(buildRequest(GROUP_PRINCIPALS, 'Write-off decision required',
                'Case ' + writeOffCase.CaseNumber + ' requests a write-off of '
                + writeOffCase.Write_Off_Requested_Amount__c + ' and is awaiting a decision.',
                writeOffCase.Id));
            writeOffStamps.add(new Case(Id = writeOffCase.Id, Escalation_Level__c = LEVEL_WRITE_OFF));
        }

        // SEND FIRST, stamp second - a failed send must retry tomorrow, not be marked as delivered.
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(requests);

        List<Case> confirmedStamps = new List<Case>();
        for (Integer i = 0; i < writeOffStamps.size(); i++) {
            Integer notifyIndex = stampIndexes[i];
            if (notifyIndex < outcomes.size() && outcomes[notifyIndex] == true) {
                confirmedStamps.add(writeOffStamps[i]);
                result.writeOffsRouted++;
            }
        }
        if (!confirmedStamps.isEmpty()) {
            new AlertWrites().updateCases(confirmedStamps);
        }
        return result;
    }

    /**
     * @param groupName Public group DeveloperName.
     * @param title     Notification title.
     * @param body      Notification body.
     * @param targetId  Case the alert links to.
     * @return The request, under the PM notification type.
     */
    private static GroupNotifier.Request buildRequest(String groupName, String title, String body, Id targetId) {
        GroupNotifier.Request request = new GroupNotifier.Request();
        request.recipientGroup = groupName;
        request.title = title;
        request.body = body;
        request.targetRecordId = targetId;
        request.notificationType = NOTIF_TYPE;
        return request;
    }

    /**
     * ESCAPED for the same reason as every other Case write in this feature: `Case` OWD is Private,
     * the Cases belong to individual property managers, and `SYSTEM_MODE` never lifts sharing. A
     * refused stamp here would re-route the same write-off to the principals every night.
     */
    private without sharing class AlertWrites {
        private void updateCases(List<Case> cases) {
            Database.update(cases, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
