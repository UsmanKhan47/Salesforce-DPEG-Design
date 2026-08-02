# Change Prompts — Broker Protection (received 2026-07-31)

Two change documents handed to the team verbatim. Source org: SDO-1Year. The user's
instruction: "Make sure not to skip anything."

---

# Change Prompt 1: Stop Creating Duplicate Leads for Competing Brokers

> Hand this document to an AI coding agent (or engineer) in a repo that already contains
> the Broker Protection module (EmailToLeadHandler / ExtractAddressQueueable /
> PropertyMatchingService / Property_Registry__c / Competing_Broker_Submission__c).
> It migrates the routing from "duplicate-flagged Lead per competing broker" to
> "submission-tracking entry only, NO Lead". All code below is the final, test-verified
> version from the source org (SDO-1Year).

## 1. Current behavior (what you are replacing)

When a **different broker** emails a property that an earlier broker already claimed, the
pipeline currently:
1. Creates a **new Lead** flagged `Is_Duplicate_Property__c = true` with
   `Duplicate_Of_Lead__c` pointing at the winner's Lead,
2. Inserts a `Competing_Broker_Submission__c` with `Source_Lead__c` = that new Lead,
3. Logs the email Task on the competing broker's own new Lead.

## 2. Target behavior (what to implement)

A competing broker gets **NO Lead at all**:
1. Insert a `Competing_Broker_Submission__c` against the winner with
   **`Source_Lead__c = null`** — the submission-tracking entry is the only record of the
   competing claim (the `competingBrokerSubmissions` LWC on the winning Lead displays it),
2. Log the email Task on the **winning Lead** (resolved through Lead conversion if the
   winner has converted), so the property's full story lives in one place,
3. Outcome label changes: `Competing Duplicate` → **`Competing Submission`**, and
   `Competing Duplicate (race)` → **`Competing Submission (race)`**.
4. A competing broker who **re-emails** the same property is a Repeat that lands on the
   **winning Lead** (they have no Lead of their own to append to).
5. The winner's own repeat behavior is unchanged (appends to their own Lead).

## 3. Why (both reasons matter — keep them in code comments)

- Duplicate-flagged Leads **pollute the Lead table** (one junk Lead per competing broker
  per property).
- Orgs commonly run **Lead duplicate rules on Email**. Inserting a second Lead with the
  same broker email throws `DUPLICATES_DETECTED`, the surrounding Savepoint **rolls back
  the whole transaction**, and the email Task is silently lost. Not inserting competing
  Leads removes this failure class structurally.

## 4. Code changes

### 4.1 `ExtractAddressQueueable.route()` — Repeat branch (branch 2)

The repeat check must (a) try **both** the LLM-extracted `broker_email` **and** the
envelope `fromAddress` (the LLM value can be blank OR wrong on auto-forwarded mail), and
(b) fall back to the **winning Lead** when the matched submission has no `Source_Lead__c`
(i.e. it belongs to a competing broker):

```apex
        // 2. Same broker + same property: a repeat. Append to the broker's OWN Lead.
        // The LLM's broker_email can be missing OR wrong on an auto-forwarded mail
        // (there is no quoted "From:" block to read), so try both it AND the
        // envelope From address - which IS the broker in the auto-forward flow.
        // Either hit means this is a repeat and must NOT spawn a second Lead (which
        // the org's duplicate rule would block anyway).
        if (String.isNotBlank(normalized)) {
            for (String candidateEmail : new List<String>{ extracted.get('broker_email'), fromAddress }) {
                if (String.isBlank(candidateEmail)) continue;
                Competing_Broker_Submission__c sub =
                    PropertyMatchingService.findBrokerSubmission(candidateEmail, normalized);
                if (sub != null) {
                    // A winner re-emailing goes to their own Lead. A competing broker
                    // has no Lead of their own, so their follow-up lands on the
                    // winning Lead alongside their submission entry.
                    Id target = sub.Source_Lead__c != null ? sub.Source_Lead__c : sub.Winning_Lead__c;
                    if (target != null) {
                        return new RoutingResult(
                            PropertyMatchingService.resolveLiveRecord(target), 'Repeat');
                    }
                }
            }
        }
```

### 4.2 `ExtractAddressQueueable.route()` — Competing branch (branch 3)

Replace the duplicate-Lead insert entirely:

```apex
        // 3. Different broker, property already claimed -> NO new Lead. The claim
        // is tracked as a Competing_Broker_Submission__c against the winner, and
        // the email itself is logged on the winning Lead. Duplicate-flagged Leads
        // polluted the Lead table and collided with org duplicate rules
        // (DUPLICATES_DETECTED rolled back the whole transaction).
        if (existing != null) {
            insert buildSubmission(existing.Winning_Lead__c, null, extracted, normalized, submittedOn, false);
            return new RoutingResult(
                PropertyMatchingService.resolveLiveRecord(existing.Winning_Lead__c), 'Competing Submission');
        }
```

### 4.3 `ExtractAddressQueueable.route()` — lost-race path

The winner Lead was already inserted before the registry claim failed; **delete it** and
log the submission entry instead of flagging it:

```apex
        } catch (DmlException de) {
            if (!isDuplicateValue(de)) throw de;

            // Lost the race. Remove the just-created Lead - the competing claim is
            // tracked as a submission entry on the winner, same as branch 3.
            Property_Registry__c winner = PropertyMatchingService.findMatchingRegistry(normalized);
            if (winner != null) {
                delete winnerLead;
                insert buildSubmission(winner.Winning_Lead__c, null, extracted, normalized, submittedOn, false);
                return new RoutingResult(
                    PropertyMatchingService.resolveLiveRecord(winner.Winning_Lead__c), 'Competing Submission (race)');
            }
            // ... orphan-adoption branch stays unchanged ...
```

### 4.4 `ExtractAddressQueueable.buildSubmission()` — broker email fallback

Competing submissions no longer have a Lead carrying the broker's email, so the
submission itself MUST hold it. Fall back to the From address when the LLM value is blank:

```apex
            Broker_Email__c = String.isNotBlank(extracted.get('broker_email'))
                              ? extracted.get('broker_email') : fromAddress,
```

### 4.5 `PropertyMatchingService.findBrokerSubmission()` — two changes

1. **Remove `Source_Lead__c != null`** from BOTH the exact and the fuzzy query (competing
   submissions now legitimately carry a null `Source_Lead__c`; the caller routes those to
   `Winning_Lead__c`).
2. Match on **`Broker_Email__c` OR `Source_Lead__r.Email`** in both queries (older winner
   rows can carry a null `Broker_Email__c`; the Lead reliably holds the address).

```apex
        List<Competing_Broker_Submission__c> exact = [
            SELECT Id, Source_Lead__c, Winning_Lead__c, Property_Key__c, Broker_Email__c
            FROM Competing_Broker_Submission__c
            WHERE (Broker_Email__c = :brokerEmail OR Source_Lead__r.Email = :brokerEmail)
              AND Property_Key__c = :normalizedAddress
            ORDER BY Submitted_Date__c ASC
            LIMIT 1
        ];
        // ... fuzzy fallback query gets the same WHERE treatment:
        //   (Broker_Email__c = :brokerEmail OR Source_Lead__r.Email = :brokerEmail)
        //   AND Submitted_Date__c >= :cutoff        <- no Source_Lead__c filter
```

Update the method doc: a winner's submission carries `Source_Lead__c` (their own Lead); a
competing broker's submission has none — the caller routes those to `Winning_Lead__c`.

### 4.6 Legacy fields

`Lead.Is_Duplicate_Property__c` and `Lead.Duplicate_Of_Lead__c` are **no longer written**
by any path. Keep them only for historical data (or drop them in a fresh org).

## 5. Test changes (all must pass)

1. **Rewrite** "different broker same property" test: assert **no** new Lead is created,
   the submission row exists with `Winning_Lead__c` = winner / `Source_Lead__c = null` /
   `Is_Winning_Submission__c = false`, the email Task is on the **winning Lead**, and the
   staging outcome is `Competing Submission` with `Result_Record_Id__c` = winner.
2. **Add** "competing broker repeats" test: seed a submission with `Source_Lead__c = null`
   for broker X on the claimed key; broker X emails the same property again → no new Lead,
   no new submission, Task on the winning Lead, outcome `Repeat`.
3. **Rewrite** the lost-race test (`forceClaimRace = true`): the racer's Lead is
   **deleted**, the submission row exists (null source, not winning), the racer's email
   Task is on the winning Lead, outcome `Competing Submission (race)`.
4. Winner-repeat, reply-thread, no-property, idempotency, orphan-adoption tests are
   unchanged and must still pass.

## 6. Verify end-to-end

1. Broker A emails property P → `New Lead (winner)`.
2. Broker B emails property P → **no Lead**; submission entry on A's Lead
   (`Competing Submission`); B's email visible in A's Lead timeline and in the
   `competingBrokerSubmissions` LWC.
3. Broker B emails P again → `Repeat`, Task appended to A's Lead, still no Lead for B.
4. Broker A emails P again → `Repeat`, Task appended to A's own Lead.
5. Confirm no `DUPLICATES_DETECTED` errors in `Inbound_Email_Staging__c.Error__c`.

---

# Change Prompt 2: EAC Thread Guard — Keep Only Deal-Thread Emails on Leads

> Hand this document to an AI coding agent (or engineer) in a repo that already contains
> the Broker Protection module (pipeline Tasks stamped with `Thread_Key__c` /
> `Inbound_Message_Id__c`) and uses **Einstein Activity Capture** to capture the agent's
> outbound replies. All code below is the final, test-verified version from the source
> org (SDO-1Year).

## 1. The problem this solves

EAC associates captured emails by **address matching only** — it is completely
**thread-blind**. It attaches every email to *every record whose address appears on it*.
Consequence: when the agent sends a broker a **brand-new, unrelated email** from the
connected mailbox, EAC staples it onto that broker's **deal Lead** (and onto every other
Lead carrying that address), polluting the timeline with conversations that have nothing
to do with the deal.

**No EAC configuration can prevent this.** There is no per-thread setting, no relevance
filter — only all-or-nothing per address. So the fix runs *after* capture: let EAC
materialize the email, then automatically delete it from the Lead when it does not belong
to any thread the pipeline anchored there. Replies in a deal thread stay; new unrelated
conversations vanish within seconds.

## 2. How EAC materializes a capture (the shape the guard relies on)

In the source org, each EAC-captured email becomes:

- an **`EmailMessage`** — `CreatedBy` = the connected-mailbox user; `ThreadIdentifier` =
  the RFC Message-ID of the **thread root** (for a reply, the original message's ID; for
  a new conversation, its own ID); `MessageIdentifier` = the email's own Message-ID;
  `ActivityId` → its companion Task;
- a **companion `Task`** created by the **Automated Process** user — this Task is what
  renders on the record's Activity Timeline;
- **`EmailMessageRelation`** rows linking the message to matched records (User / Lead /
  Contact) by address.

The pipeline, meanwhile, logs every inbound broker email as a Task on the Lead stamped
with `Thread_Key__c` (conversation root) and `Inbound_Message_Id__c` (the message's own
ID). Those are the **thread anchors**.

**The rule:** an EAC-materialized email may stay on a Lead **only if** its
`ThreadIdentifier` (or `MessageIdentifier`) matches an anchor on that Lead. Verified in
real data: a genuine reply carries `ThreadIdentifier` = the broker's original Message-ID
(= the anchor); an unrelated new conversation carries its own fresh ID (no anchor).

> ⚠ **Precondition — verify in the target org first:** this only works where EAC stores
> captures as queryable `EmailMessage` records (as this org does). Classic EAC that keeps
> data only in the external store never materializes anything to guard. Send a test email
> and query `EmailMessage` to confirm before installing.

## 3. Components (deploy all three)

### 3.1 `triggers/EmailMessageThreadGuard.trigger`

```apex
/**
 * Enqueues the thread guard for every new EmailMessage. Async on purpose:
 * EmailMessageRelation rows are written after the EmailMessage in the same
 * transaction, so the association check must run post-commit.
 */
trigger EmailMessageThreadGuard on EmailMessage (after insert) {
    if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
        System.enqueueJob(new EmailThreadGuardQueueable(Trigger.newMap.keySet()));
    }
}
```

### 3.2 `classes/EmailThreadGuardQueueable.cls`

```apex
/**
 * Cleans up EAC's address-based over-association on Leads.
 *
 * EAC attaches every captured email to ANY record whose address appears on it -
 * it is thread-blind, so a brand-new conversation with a broker lands on that
 * broker's deal Lead even though it has nothing to do with the deal. This guard
 * enforces thread-level association after capture: an EAC-materialized email may
 * stay on a Lead only if its ThreadIdentifier (or MessageIdentifier) matches a
 * thread anchor the pipeline logged on that Lead (Task.Thread_Key__c /
 * Task.Inbound_Message_Id__c). Anything else is deleted together with its
 * companion timeline Task.
 *
 * Scope guards - it only ever deletes when ALL of these hold:
 *   - the EmailMessage is related to at least one Lead,
 *   - its companion Task (ActivityId) was created by the Automated Process user
 *     (the EAC materialization fingerprint - deliberate composer/Agentforce sends
 *     have a real user as creator and are never touched),
 *   - no related Lead carries a matching thread anchor.
 *
 * If EAC ever re-syncs a deleted email, the trigger fires again and re-deletes:
 * the guard is self-healing.
 */
public class EmailThreadGuardQueueable implements Queueable {

    /**
     * Test seam: companion Tasks created in tests are owned by the running user,
     * so the AutomatedProcess fingerprint can never be reproduced in a test
     * context. Setting this treats every candidate as EAC-materialized.
     */
    @TestVisible private static Boolean treatAllAsMaterialized = false;

    private Set<Id> messageIds;

    public EmailThreadGuardQueueable(Set<Id> messageIds) {
        this.messageIds = messageIds;
    }

    public void execute(QueueableContext ctx) {
        run(messageIds);
    }

    public static void run(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) return;

        List<EmailMessage> msgs = [
            SELECT Id, ThreadIdentifier, MessageIdentifier, ActivityId
            FROM EmailMessage WHERE Id IN :ids
        ];
        if (msgs.isEmpty()) return;

        // Which Leads is each message related to?
        Map<Id, Set<Id>> msgLeads = new Map<Id, Set<Id>>();
        for (EmailMessageRelation r : [
            SELECT EmailMessageId, RelationId
            FROM EmailMessageRelation
            WHERE EmailMessageId IN :ids
              AND RelationObjectType = 'Lead'
              AND RelationId != null
        ]) {
            if (!msgLeads.containsKey(r.EmailMessageId)) {
                msgLeads.put(r.EmailMessageId, new Set<Id>());
            }
            msgLeads.get(r.EmailMessageId).add(r.RelationId);
        }
        if (msgLeads.isEmpty()) return; // nothing Lead-related: not our concern

        // Companion Tasks (the platform links them via ActivityId): the
        // AutomatedProcess creator is the EAC fingerprint.
        Set<Id> taskIds = new Set<Id>();
        for (EmailMessage m : msgs) {
            if (m.ActivityId != null) taskIds.add(m.ActivityId);
        }
        Map<Id, Task> companions = taskIds.isEmpty()
            ? new Map<Id, Task>()
            : new Map<Id, Task>([SELECT Id, CreatedBy.UserType FROM Task WHERE Id IN :taskIds]);

        // Thread anchors the pipeline logged on the related Leads.
        Set<Id> allLeads = new Set<Id>();
        for (Set<Id> s : msgLeads.values()) allLeads.addAll(s);
        Set<String> candidateIds = new Set<String>();
        for (EmailMessage m : msgs) {
            if (String.isNotBlank(m.ThreadIdentifier))  candidateIds.add(m.ThreadIdentifier);
            if (String.isNotBlank(m.MessageIdentifier)) candidateIds.add(m.MessageIdentifier);
        }
        Map<Id, Set<String>> leadAnchors = new Map<Id, Set<String>>();
        if (!candidateIds.isEmpty()) {
            for (Task t : [
                SELECT WhoId, Thread_Key__c, Inbound_Message_Id__c
                FROM Task
                WHERE WhoId IN :allLeads
                  AND (Thread_Key__c IN :candidateIds OR Inbound_Message_Id__c IN :candidateIds)
            ]) {
                if (!leadAnchors.containsKey(t.WhoId)) leadAnchors.put(t.WhoId, new Set<String>());
                if (t.Thread_Key__c != null)          leadAnchors.get(t.WhoId).add(t.Thread_Key__c);
                if (t.Inbound_Message_Id__c != null)  leadAnchors.get(t.WhoId).add(t.Inbound_Message_Id__c);
            }
        }

        List<EmailMessage> doomedMsgs  = new List<EmailMessage>();
        List<Task>         doomedTasks = new List<Task>();
        for (EmailMessage m : msgs) {
            if (!msgLeads.containsKey(m.Id)) continue;

            Task companion = m.ActivityId != null ? companions.get(m.ActivityId) : null;
            Boolean eacMaterialized = treatAllAsMaterialized
                || (companion != null && companion.CreatedBy.UserType == 'AutomatedProcess');
            if (!eacMaterialized) continue;

            Boolean anchored = false;
            for (Id leadId : msgLeads.get(m.Id)) {
                Set<String> anchors = leadAnchors.get(leadId);
                if (anchors != null
                    && (anchors.contains(m.ThreadIdentifier) || anchors.contains(m.MessageIdentifier))) {
                    anchored = true;
                    break;
                }
            }
            if (!anchored) {
                doomedMsgs.add(new EmailMessage(Id = m.Id));
                if (companion != null) doomedTasks.add(new Task(Id = companion.Id));
            }
        }

        // Tasks first, then messages. allOrNone=false because the two deletes can
        // cascade into each other (EAC links them), so the second may find its row
        // already gone - that is success, not failure.
        if (!doomedTasks.isEmpty()) {
            for (Database.DeleteResult dr : Database.delete(doomedTasks, false)) {
                if (!dr.isSuccess()) System.debug('### guard task delete: ' + dr.getErrors());
            }
        }
        if (!doomedMsgs.isEmpty()) {
            for (Database.DeleteResult dr : Database.delete(doomedMsgs, false)) {
                if (!dr.isSuccess()) System.debug('### guard msg delete: ' + dr.getErrors());
            }
        }
    }
}
```

### 3.3 `classes/EmailThreadGuardQueueableTest.cls`

```apex
@isTest
private class EmailThreadGuardQueueableTest {

    private static Lead makeLead() {
        Lead l = new Lead(LastName = 'Broker', Company = 'Test Co', Status = 'New',
                          Email = 'guard.broker@example.com');
        insert l;
        return l;
    }

    /**
     * EmailMessage + Lead relation, the shape EAC materializes. Enhanced Email
     * auto-creates the companion Task and stamps ActivityId on insert, so the
     * record is re-read to pick it up.
     */
    private static EmailMessage makeCapturedEmail(Id leadId, String threadId, String messageId) {
        EmailMessage m = new EmailMessage(
            Subject = 'captured', Status = '3', Incoming = false,
            ThreadIdentifier = threadId, MessageIdentifier = messageId,
            FromAddress = 'junior@example.com', ToAddress = 'guard.broker@example.com');
        insert m;
        insert new EmailMessageRelation(EmailMessageId = m.Id, RelationId = leadId,
                                        RelationType = 'ToAddress');
        return [SELECT Id, ActivityId, ThreadIdentifier, MessageIdentifier
                FROM EmailMessage WHERE Id = :m.Id];
    }

    @isTest
    static void unanchoredEmailIsRemovedFromLead() {
        Lead l = makeLead();
        // The Lead's deal thread is <root@deal>; the captured email is a NEW thread.
        insert new Task(WhoId = l.Id, Subject = 'Email: deal', Status = 'Completed',
                        TaskSubtype = 'Email', Thread_Key__c = '<root@deal>',
                        Inbound_Message_Id__c = '<root@deal>');
        EmailMessage noise = makeCapturedEmail(l.Id, '<new-convo@mail>', '<new-convo@mail>');
        Id companionId = noise.ActivityId;

        EmailThreadGuardQueueable.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardQueueable.run(new Set<Id>{ noise.Id });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :noise.Id],
            'an email from an unknown thread must be removed from the Lead');
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'its companion timeline Task must be removed too');
    }

    @isTest
    static void threadReplyIsKept() {
        Lead l = makeLead();
        insert new Task(WhoId = l.Id, Subject = 'Email: deal', Status = 'Completed',
                        TaskSubtype = 'Email', Thread_Key__c = '<root@deal>',
                        Inbound_Message_Id__c = '<root@deal>');
        // A reply in the deal thread: ThreadIdentifier = the anchored root.
        EmailMessage reply = makeCapturedEmail(l.Id, '<root@deal>', '<reply-1@mail>');

        EmailThreadGuardQueueable.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardQueueable.run(new Set<Id>{ reply.Id });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :reply.Id],
            'a reply within the deal thread must stay on the Lead');
    }

    @isTest
    static void deliberateSendIsNeverTouched() {
        Lead l = makeLead();
        // No anchor at all - but the companion Task is NOT AutomatedProcess-created
        // (seam off), so the guard must leave it alone.
        EmailMessage sent = makeCapturedEmail(l.Id, '<composer@mail>', '<composer@mail>');

        EmailThreadGuardQueueable.treatAllAsMaterialized = false;
        Test.startTest();
        EmailThreadGuardQueueable.run(new Set<Id>{ sent.Id });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :sent.Id],
            'emails logged by a real user (composer/Agentforce) must never be deleted');
    }

    @isTest
    static void nonLeadEmailIsIgnored() {
        // Related to nothing Lead-shaped: the guard must not touch it.
        EmailMessage m = new EmailMessage(
            Subject = 'user to user', Status = '3', Incoming = false,
            ThreadIdentifier = '<x@mail>', MessageIdentifier = '<x@mail>',
            FromAddress = 'a@example.com', ToAddress = 'b@example.com');
        insert m;

        EmailThreadGuardQueueable.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardQueueable.run(new Set<Id>{ m.Id });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :m.Id]);
    }
}
```

Meta XML for all three: apiVersion 63.0, status Active.

## 4. Hard-won gotchas (they cost real debugging time — do not rediscover them)

1. **`EmailMessage.ActivityId` is system-writable only.** Tests cannot set it — but they
   don't need to: **Enhanced Email auto-creates the companion Task on insert** and stamps
   `ActivityId`. Re-read the record after insert to get it.
2. **The AutomatedProcess fingerprint cannot be reproduced in tests** (test-created Tasks
   are owned by the running user) — hence the `treatAllAsMaterialized` seam.
3. **The message/Task deletes cascade into each other.** A hard `delete` throws
   `ENTITY_IS_DELETED` on the second one. Use `Database.delete(..., false)` and treat
   already-gone rows as success.
4. **The trigger must be async** (queueable): `EmailMessageRelation` rows are inserted
   *after* the `EmailMessage` in the same transaction; checking associations in the
   trigger itself would see none.
5. **Deliberate sends are distinguishable**: composer/Agentforce emails have a companion
   Task created by a *real user*; EAC-materialized ones by *Automated Process*. Guard on
   `CreatedBy.UserType == 'AutomatedProcess'` and intentional logs are never touched.
6. Deleted emails are removed from Salesforce **entirely** (they still exist in the
   mailbox). If EAC re-syncs one, the trigger deletes it again — self-healing.
7. Scope is **Leads only** by design. Extend `RelationObjectType` handling if you later
   want the same guard for Contacts/Opportunities.

## 5. Install steps

1. Deploy the class, test class, and trigger.
2. Run `EmailThreadGuardQueueableTest` — all 4 must pass.
3. **One-off sweep** of already-materialized noise (anonymous Apex; widen the date filter
   as needed):

```apex
Set<Id> ids = new Map<Id, EmailMessage>(
    [SELECT Id FROM EmailMessage WHERE CreatedDate = LAST_N_DAYS:7]
).keySet();
EmailThreadGuardQueueable.run(ids);
```

4. Verify end-to-end:
   - Reply within a deal thread from the connected mailbox → still appears on the Lead.
   - Send a brand-new unrelated email to a broker → captured by EAC, then removed by the
     guard within seconds; never persists on the Lead.
   - Emails sent from the Salesforce composer on a Lead remain untouched.
