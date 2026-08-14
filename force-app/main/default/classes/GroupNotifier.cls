/**
 * Generic in-app notifier for the acquisition deal lifecycle. Sends a custom
 * notification (type: Acquisitions_Deal_Update) to every user member of a public
 * group or queue, identified by DeveloperName. Callable from flows (invocable)
 * and directly from Apex services.
 *
 * Groups are kept flat by convention (no nested groups); user members are
 * resolved one level deep. A notification failure must never roll back the
 * calling transaction, so every failure path degrades to a debug warning.
 *
 * `without sharing` justification (ARCHITECTURE.md §2): this is an
 * automation/notification utility invoked from triggers, services and flows for
 * the acquisition deal lifecycle. It must resolve group/queue membership and send
 * to the target record's watchers independently of whoever triggered the
 * transaction — the audience of a deal-update notification is defined by the
 * recipient group, not by the running user's sharing. Declared `without sharing`
 * so membership resolution and delivery are not silently narrowed by the caller's
 * record visibility. It performs no record DML and cannot leak data to the caller.
 */
public without sharing class GroupNotifier {

    private static final String NOTIF_TYPE_DEV_NAME = 'Acquisitions_Deal_Update';
    private static final String USER_KEY_PREFIX = '005';

    // Test hook: custom notifications cannot be queried in Apex tests, so tests
    // assert against the number of successful sends instead.
    @TestVisible private static Integer sentCount = 0;

    // Transaction-scoped caches. notify() is already O(1) in queries for any one
    // call, but a caller that loops send() re-enters it once per record and pays
    // 3 fresh queries every time (measured: 9 queries per Opportunity in
    // ContractExecutionService, 1,800 for a 200-record trigger chunk). Callers
    // should batch into a single notify() - these caches are the guardrail that
    // keeps a looping caller from silently reintroducing a governor break.
    private static Id cachedNotificationTypeId;
    private static Boolean notificationTypeResolved = false;
    private static final Map<String, Set<String>> RECIPIENTS_CACHE = new Map<String, Set<String>>();

    public class Request {
        @InvocableVariable(label='Group or Queue DeveloperName' required=true)
        public String recipientGroup;
        @InvocableVariable(label='Title' required=true)
        public String title;
        @InvocableVariable(label='Body' required=true)
        public String body;
        @InvocableVariable(label='Target Record Id' required=true)
        public Id targetRecordId;
    }

    /** Direct entry point for Apex callers. */
    public static void send(String groupDevName, String title, String body, Id targetId) {
        Request r = new Request();
        r.recipientGroup = groupDevName;
        r.title = title;
        r.body = body;
        r.targetRecordId = targetId;
        notify(new List<Request>{ r });
    }

    @InvocableMethod(
        label='Notify Group or Queue'
        description='Sends an Acquisitions Deal Update custom notification to all members of a public group or queue.'
    )
    public static void notify(List<Request> requests) {
        notifyWithOutcome(requests);
    }

    /**
     * `notify`, but it TELLS THE CALLER WHAT HAPPENED — one Boolean per request, index-aligned to
     * the input list.
     *
     * ═══ 🔴 WHY THIS EXISTS AT ALL (added 2026-08-14 for CallForOffersAlertBatch) ═══
     * `notify` swallows every failure by design, which is right for its original callers: a failed
     * deal-update notification must never roll back the transaction that triggered it, and there is
     * nothing for them to do about it. It is WRONG for a caller that writes an IDEMPOTENCY MARKER
     * after sending, because a swallowed failure leaves exactly two options and both are defects:
     *
     *   stamp anyway  -> the alert is lost FOREVER, silently. The marker says it was sent.
     *   never stamp   -> the same alert fires every single day, which is the failure the whole
     *                    marker design exists to prevent ("the team stops reading them").
     *
     * With an outcome the caller stamps only what actually went out, so a failed send is retried on
     * the next pass and a successful one is never repeated.
     *
     * ⚠ THE `@InvocableMethod` SIGNATURE IS UNTOUCHED. `notify` keeps its `void` return and remains
     * the Flow entry point; it now delegates here and discards the answer, so every existing caller
     * and every Flow is byte-for-byte unaffected. Do not add `@InvocableMethod` to this method —
     * an object with two invocable methods is a Flow-picker ambiguity for no gain.
     *
     * ⚠ WHAT `false` DOES AND DOES NOT MEAN. It means "this request produced no notification":
     * a null/blank request, a missing notification type, a group that resolved to no recipients, or
     * a `send()` that threw. It does NOT mean the notification failed to be READ. There is no
     * delivery receipt available to Apex and none is claimed here.
     *
     * @param requests The notifications to send; null/empty safe.
     * @return One Boolean per input request, in input order — true only when `send()` returned
     *         without throwing. Empty when the input is null or empty. Never null.
     */
    public static List<Boolean> notifyWithOutcome(List<Request> requests) {
        List<Boolean> outcomes = new List<Boolean>();
        if (requests == null || requests.isEmpty()) {
            return outcomes;
        }
        // Pre-fill with false so an early return below still returns an index-aligned list. A
        // caller that trusted a SHORT list would silently stamp the wrong records.
        for (Integer i = 0; i < requests.size(); i++) {
            outcomes.add(false);
        }

        Id notificationTypeId = resolveNotificationTypeId();
        if (notificationTypeId == null) {
            System.debug(LoggingLevel.WARN, 'GroupNotifier: notification type missing: ' + NOTIF_TYPE_DEV_NAME);
            return outcomes;
        }

        Set<String> groupNames = new Set<String>();
        for (Request r : requests) {
            if (r != null && String.isNotBlank(r.recipientGroup)) {
                groupNames.add(r.recipientGroup);
            }
        }
        Map<String, Set<String>> recipientsByGroup = resolveRecipients(groupNames);

        for (Integer i = 0; i < requests.size(); i++) {
            Request r = requests[i];
            if (r == null || String.isBlank(r.recipientGroup) || r.targetRecordId == null) {
                continue;
            }
            Set<String> recipients = recipientsByGroup.get(r.recipientGroup);
            if (recipients == null || recipients.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'GroupNotifier: no recipients for group ' + r.recipientGroup);
                continue;
            }
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(notificationTypeId);
            n.setTargetId(r.targetRecordId);
            n.setTitle(r.title);
            n.setBody(r.body);
            // 🔴 ONE CALL, THE WHOLE MEMBER SET — SO THE COST OF THIS LINE IS A FUNCTION OF GROUP
            // SIZE, NOT A CONSTANT. Measured on `usman-dpeg` 2026-08-14, call count held fixed
            // while |recipients| varied inside one transaction:
            //
            //     one send()  ≈  6.0 ms CPU  +  0.22 ms x |recipients|
            //
            // (1 recipient = 6.24 ms, 6 = 7.34 ms, over three paired rounds of 30 calls; a
            // 1-recipient drift control repeated to 5.900 ms exactly.) Zero SOQL and zero DML
            // either way. So a looping caller pays mostly PER CALL, which is why the caches above
            // are the guardrail that matters — but a caller sizing a batch chunk against CPU must
            // carry the recipient count as a multiplier rather than quoting a flat per-send figure.
            // `CallForOffersAlertBatch`'s header §1 does that arithmetic; it is the only caller
            // whose chunk size depends on it.
            //
            // ⚠ AND THE PER-RECIPIENT TERM IS SYNCHRONOUS VALIDATION, NOT ASYNC DELIVERY — which
            // is why ONE BAD ID KILLS THE WHOLE CALL. A recipient Id that resolves to nothing
            // raises `System.HandledException: Invalid parameter value for: recipientIds` and NO
            // recipient in the set is notified (measured: sentOk = 0 across every attempt).
            // `resolveRecipients` only ever emits live `GroupMember.UserOrGroupId` values or a real
            // group Id, so this is not reachable today; it is recorded because the failure is
            // all-or-nothing per group rather than per member, and the `catch` below reports it as
            // a single `false` for the request.
            try {
                n.send(recipients);
                sentCount++;
                outcomes[i] = true;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'GroupNotifier: send failed for ' + r.recipientGroup + ': ' + e.getMessage());
            }
        }
        return outcomes;
    }

    /**
     * Resolves the notification type Id once per transaction. Cached because a
     * looping caller would otherwise re-query it per send.
     * @return The Acquisitions_Deal_Update notification type Id, or null when absent.
     */
    private static Id resolveNotificationTypeId() {
        if (!notificationTypeResolved) {
            notificationTypeResolved = true;
            // SOQL relocated to NotificationTypeSelector (P4 §2 layering).
            CustomNotificationType notifType =
                NotificationTypeSelector.selectByDeveloperName(NOTIF_TYPE_DEV_NAME);
            cachedNotificationTypeId = (notifType == null) ? null : notifType.Id;
        }
        return cachedNotificationTypeId;
    }

    /**
     * Maps each group DeveloperName to its recipient Ids: direct user members,
     * falling back to the group Id itself when the group has no user members
     * (queues accept their own Id as a notification recipient).
     *
     * Results are cached for the transaction. A group that does not exist caches
     * an EMPTY set - distinct from an existing-but-empty group, which caches the
     * group's own Id. That distinction is load-bearing: the caller warns on the
     * former and sends on the latter.
     */
    private static Map<String, Set<String>> resolveRecipients(Set<String> groupNames) {
        Map<String, Set<String>> result = new Map<String, Set<String>>();
        if (groupNames.isEmpty()) {
            return result;
        }

        Set<String> uncachedNames = new Set<String>();
        for (String name : groupNames) {
            if (RECIPIENTS_CACHE.containsKey(name)) {
                Set<String> cached = RECIPIENTS_CACHE.get(name);
                if (!cached.isEmpty()) {
                    result.put(name, cached);
                }
            } else {
                uncachedNames.add(name);
            }
        }
        if (uncachedNames.isEmpty()) {
            return result;
        }
        groupNames = uncachedNames;

        // SOQL relocated to per-object selectors (P4 §2 layering). The Group lookup
        // spans Type IN ('Regular','Queue') — broader than QueueGroupSelector's
        // Queue-only method — hence selectRegularAndQueueByDeveloperNames.
        Map<Id, String> groupIdToName = new Map<Id, String>();
        for (Group g : QueueGroupSelector.selectRegularAndQueueByDeveloperNames(groupNames)) {
            groupIdToName.put(g.Id, g.DeveloperName);
            result.put(g.DeveloperName, new Set<String>());
        }
        for (GroupMember gm : GroupMemberSelector.selectByGroupIds(groupIdToName.keySet())) {
            if (String.valueOf(gm.UserOrGroupId).startsWith(USER_KEY_PREFIX)) {
                result.get(groupIdToName.get(gm.GroupId)).add(gm.UserOrGroupId);
            }
        }
        // Empty group: fall back to the group Id (proven to work for queues).
        for (Id gId : groupIdToName.keySet()) {
            String name = groupIdToName.get(gId);
            if (result.get(name).isEmpty()) {
                result.get(name).add(gId);
            }
        }
        // Cache what we resolved, including negatives (name queried, no group found).
        for (String name : groupNames) {
            Set<String> resolved = result.containsKey(name) ? result.get(name) : new Set<String>();
            RECIPIENTS_CACHE.put(name, resolved);
        }
        return result;
    }
}