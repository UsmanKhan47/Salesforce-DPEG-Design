/**
 * Tests for EmailThreadAnchorService — the SHARED thread-anchor index that the EAC
 * adopter and the EAC guard both consume, with opposite polarity.
 *
 * ═══ WHAT THIS CLASS EXISTS TO PROTECT ═══
 * Two things, and both of them are load-bearing for the two features that sit on top:
 *
 *   1. **THE NORMALIZATION (defect P4).** The pipeline stores `Thread_Key__c`
 *      UNBRACKETED and `Inbound_Message_Id__c` BRACKETED — measured on both live anchor
 *      rows in `usman-dpeg` 2026-08-02 (experiment E3) — while EAC supplies bracketed
 *      identifiers. Before this class existed the deployed guard compared raw values, so
 *      its `ThreadIdentifier ↔ Thread_Key__c` leg could NEVER match and it was running on
 *      one leg only. `bracketAsymmetryIsClosedByNormalization` is named in the production
 *      class header and goes red the moment anyone removes the normalizer.
 *   2. **THE FAIL-CLOSED RESOLUTION CHAIN (D2, as reshaped by E1).** Resolution happens
 *      ONLY through an anchor Task's `WhatId` when that WhatId is an Opportunity. A
 *      Contact `WhoId` resolves NOTHING, deliberately: after conversion every anchor's
 *      WhoId IS a Contact, and one Contact can front many deals, so resolving through it
 *      would manufacture exactly the wrong-deal lie the guard exists to delete.
 *
 * ═══ `isMessageIdAnchoredOn` — THE THIRD ACCESSOR (added 2026-08-04, guard 5 / timeline
 * dedup) ═══
 * Message-ID ONLY, per record, NOT first-wins — the exact opposite shape from
 * `resolveOpportunity`. Tests below pin, directly on the accessor rather than only
 * end-to-end through the guard (EmailThreadGuardServiceTest owns the end-to-end
 * pinning): it must NOT be satisfied by a Thread_Key__c-only match (the single easiest
 * "simplification" that would delete outbound mail and every EAC copy of a
 * pipeline-unseen reply — see the accessor's own header), it must be bracket-agnostic
 * (reusing `normalize`, not reimplementing it — defect P4), and it must be record-scoped
 * (a Message-ID anchored on one record must not satisfy a query about a different one).
 *
 * ═══ WHY MOST TESTS HERE DO NO EmailMessage DML ═══
 * `index(List<EmailMessage>)` takes records, not Ids, so an UNSAVED EmailMessage is a
 * perfectly good capture for everything except the `Set<Id>` overload. That keeps these
 * tests fast and, more usefully, keeps them free of the Enhanced Email companion-Task
 * side effects that the adopter and guard suites have to manage.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes.
 *
 * @see EmailThreadAnchorService.cls (the normalization, the E1 note, the tie-break)
 * @see EmailThreadAdopterServiceTest.cls / EmailThreadGuardServiceTest.cls (the consumers)
 */
@isTest
private class EmailThreadAnchorServiceTest {

    private static final String DEAL_ROOT = 'root@deal.example.invalid';
    private static final String OTHER_ROOT = 'other-root@deal.example.invalid';

    // ─────────────────────────────────────────────────────────────────────────
    // normalize — the ONLY bracket handling in either feature
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Both RFC forms of the same identifier must reduce to one value, whitespace and
     * all. Everything else in this feature compares normalized strings, so this is the
     * function every match ultimately runs through.
     */
    @isTest
    static void normalize_stripsAngleBracketsAndTrims() {
        Assert.areEqual(DEAL_ROOT, EmailThreadAnchorService.normalize('<' + DEAL_ROOT + '>'),
            'A bracketed RFC identifier must normalize to its bare value');
        Assert.areEqual(DEAL_ROOT, EmailThreadAnchorService.normalize(DEAL_ROOT),
            'An already-bare identifier must survive normalization unchanged');
        Assert.areEqual(DEAL_ROOT, EmailThreadAnchorService.normalize('  <' + DEAL_ROOT + '>  '),
            'Surrounding whitespace must not defeat a match — headers arrive padded');
    }

    /**
     * Nothing-shaped input must produce null rather than an empty string: an empty string
     * would be a VALUE, and a value can match another empty value, which is how a
     * "match everything" bug gets born.
     */
    @isTest
    static void normalize_blankOrEmptyBrackets_returnsNull() {
        Assert.isNull(EmailThreadAnchorService.normalize(null),
            'null in, null out');
        Assert.isNull(EmailThreadAnchorService.normalize('   '),
            'Whitespace is not an identifier');
        Assert.isNull(EmailThreadAnchorService.normalize('<>'),
            'Empty brackets must not normalize to an empty string — an empty anchor value '
            + 'would match every other empty value and anchor everything to everything');
    }

    /**
     * 🔴 THE P4 REGRESSION TEST, named in EmailThreadAnchorService's class header.
     *
     * The anchor is stored the way `computeThreadKey` stores it — UNBRACKETED — while the
     * capture carries EAC's raw BRACKETED `ThreadIdentifier`. These two must match. Before
     * the shared normalizer they could not, and the deployed guard was silently running on
     * its MessageIdentifier leg alone.
     */
    @isTest
    static void bracketAsymmetryIsClosedByNormalization() {
        Lead broker = TestDataFactory.createLead(true);
        // Stored UNBRACKETED, exactly as PropertyMatchingService.computeThreadKey writes it.
        insert anchorOnWho(broker.Id, DEAL_ROOT, null);
        // EAC supplies the BRACKETED form.
        EmailMessage capture = buildCapture('<' + DEAL_ROOT + '>', '<reply-1@mail.example.invalid>');

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.isTrue(anchors.isAnchoredOn(broker.Id, capture),
            'An anchor stored UNBRACKETED must match a BRACKETED ThreadIdentifier. If this '
            + 'fails the normalizer is gone and the guard is back to running on one leg — '
            + 'anchored mid-thread replies would be deleted as unanchored');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // resolveOpportunity — the D2 chain, reduced to its two reachable branches by E1
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The ONE resolving branch: the anchor Task's `WhatId` is an Opportunity. Experiment
     * E1 showed standard conversion stamps this itself, which is why no conversion-time
     * carry-forward was built.
     */
    @isTest
    static void resolveOpportunity_anchorWhatIdIsTheOpportunity() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT, null);
        EmailMessage capture = buildCapture(DEAL_ROOT, 'reply-1@mail.example.invalid');

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.areEqual(deal.Id, anchors.resolveOpportunity(capture),
            'A thread anchored on a Task whose WhatId is an Opportunity must resolve to '
            + 'that Opportunity — this is the adopter entire resolution chain');
    }

    /**
     * 🔴 FAIL CLOSED, AND THIS IS THE SAFETY PROPERTY. After conversion every anchor's
     * `WhoId` is a CONTACT, and one broker Contact fronts many deals. Resolving through
     * a Contact would adopt captures onto whichever deal happened to be looked up first —
     * the wrong-deal lie the guard exists to delete. Adopting nothing is strictly better.
     */
    @isTest
    static void resolveOpportunity_anchorOnAContactOnly_failsClosed() {
        Contact brokerContact = TestDataFactory.createBrokerContact(null, true);
        insert anchorOnWho(brokerContact.Id, DEAL_ROOT, null);
        EmailMessage capture = buildCapture(DEAL_ROOT, 'reply-1@mail.example.invalid');

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.isTrue(anchors.isAnchoredOn(brokerContact.Id, capture),
            'Precondition: the anchor IS found on the Contact — this test must fail for the '
            + 'resolution reason, not because the index missed the row');
        Assert.isNull(anchors.resolveOpportunity(capture),
            'A Contact-only anchor must resolve NO Opportunity. A Contact can front many '
            + 'deals; guessing one manufactures a plausible email on the wrong deal');
    }

    /**
     * 🔴 CONSULTATION ORDER — EXACT IDENTITY BEATS CONVERSATION-LEVEL IDENTITY (review
     * finding W1). This is the SIBLING-DEAL shape D1 multi-property extraction makes
     * routine, reproduced in miniature: one conversation root shared by two anchors that,
     * after conversion, sit on two DIFFERENT deals, plus a per-message anchor naming the
     * second. The capture carries (root, its-own-id), so it IS the email the pipeline
     * filed on deal 2 — and `MessageIdentifier` is the only signal that says so.
     *
     * Thread-first resolution would return `threadDeal` here, which is exactly the defect
     * this test exists to prevent: swap the two lookups back in `resolveOpportunity` and
     * this goes RED. The harm it guards against is bounded (always a sibling deal from the
     * same email, never an unrelated deal), which is why it was a warning and not a block.
     *
     * `resolveOpportunity_anchorWhatIdIsTheOpportunity` covers the complementary direction
     * — a capture whose own id anchors nothing still resolves through the thread root.
     */
    @isTest
    static void resolveOpportunity_messageIdentifierWinsOverThreadIdentifier() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(2, true);
        Opportunity threadDeal = deals[0];
        Opportunity messageDeal = deals[1];
        String ownMessageId = 'own-id@mail.example.invalid';
        insert new List<Task>{
            anchorOnWhat(threadDeal.Id, DEAL_ROOT, null),
            anchorOnWhat(messageDeal.Id, null, ownMessageId)
        };
        EmailMessage capture = buildCapture(DEAL_ROOT, ownMessageId);

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.areNotEqual(threadDeal.Id, messageDeal.Id,
            'Precondition: the two anchors must name DIFFERENT deals or this proves nothing');
        Assert.areEqual(messageDeal.Id, anchors.resolveOpportunity(capture),
            'MessageIdentifier must be consulted BEFORE ThreadIdentifier. The per-message '
            + 'anchor says the pipeline filed THIS SPECIFIC EMAIL on that deal; the thread '
            + 'root only says something in the conversation was filed somewhere. Resolving '
            + 'thread-first adopts a multi-property email onto a SIBLING deal');
    }

    /**
     * MULTI-ANCHOR TIE-BREAK. One Message-ID can carry N anchor Tasks across N records
     * (multi-property routing), but `RelatedToId` holds ONE Id, so resolution must be
     * DETERMINISTIC. The rule is the pipeline's own: the selector orders
     * `CreatedDate DESC, Id DESC` and this service takes first-wins.
     *
     * The expected value is derived by re-running that ordering rather than by assuming
     * insert order maps to Id order — so the test pins the RULE, not an accident of how
     * the platform happened to allocate Ids.
     */
    @isTest
    static void resolveOpportunity_multipleAnchors_takeTheSelectorsFirstRow() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(2, true);
        insert new List<Task>{
            anchorOnWhat(deals[0].Id, DEAL_ROOT, null),
            anchorOnWhat(deals[1].Id, DEAL_ROOT, null)
        };
        EmailMessage capture = buildCapture(DEAL_ROOT, 'reply-1@mail.example.invalid');
        Id expected = [
            SELECT WhatId FROM Task
            WHERE Thread_Key__c = :DEAL_ROOT
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ].WhatId;

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.areNotEqual(deals[0].Id, deals[1].Id,
            'Precondition: two DIFFERENT deals must compete, or the tie-break is untested');
        Assert.areEqual(expected, anchors.resolveOpportunity(capture),
            'With several anchors on one thread the FIRST row of the selector ordering '
            + '(CreatedDate DESC, Id DESC) must win — the pipeline inserts in ASCENDING '
            + 'priority, so the deal DPEG owns carries the highest Id and wins here');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // index — both overloads, and the guard clauses
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The `Set<Id>` overload is what EmailCaptureQueueable calls, and it exists so the
     * queueable holds no SOQL of its own. It must read the captures itself and produce
     * the same index the record-taking overload does.
     */
    @isTest
    static void index_fromMessageIds_readsTheCapturesItself() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT, null);
        EmailMessage capture = buildCapture(DEAL_ROOT, 'reply-1@mail.example.invalid');
        insert capture;

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.isFalse(anchors.isEmpty(),
            'The Id overload must load the captures through EmailMessageSelector and match '
            + 'their identifiers — an empty index here means the queueable is running blind');
        Assert.areEqual(deal.Id,
            anchors.resolveOpportunity([
                SELECT Id, ThreadIdentifier, MessageIdentifier, ActivityId, RelatedToId
                FROM EmailMessage WHERE Id = :capture.Id
            ]),
            'and it must resolve exactly as the record-taking overload does');
    }

    /**
     * Null input on EITHER overload is a no-op that returns a usable, empty index — never
     * null and never an exception. The sweep path passes whatever a date-window query
     * returned, which is legitimately nothing on a quiet day.
     */
    @isTest
    static void index_nullInput_returnsAnEmptyIndex() {
        Test.startTest();
        EmailThreadAnchorService.AnchorIndex fromNullList =
            EmailThreadAnchorService.index((List<EmailMessage>) null);
        EmailThreadAnchorService.AnchorIndex fromNullIds =
            EmailThreadAnchorService.index((Set<Id>) null);
        Test.stopTest();

        Assert.isTrue(fromNullList.isEmpty(), 'A null message list must produce an empty index');
        Assert.isTrue(fromNullIds.isEmpty(), 'A null Id set must produce an empty index');
        Assert.isNull(fromNullIds.resolveOpportunity(buildCapture(DEAL_ROOT, DEAL_ROOT)),
            'An empty index must resolve nothing rather than throw');
    }

    /**
     * Empty input, tested separately from null because they reach the guard clauses by
     * different routes and a future refactor can easily fix one and break the other.
     */
    @isTest
    static void index_emptyInput_returnsAnEmptyIndex() {
        Test.startTest();
        EmailThreadAnchorService.AnchorIndex fromEmptyList =
            EmailThreadAnchorService.index(new List<EmailMessage>());
        EmailThreadAnchorService.AnchorIndex fromEmptyIds =
            EmailThreadAnchorService.index(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(fromEmptyList.isEmpty(), 'An empty message list must produce an empty index');
        Assert.isTrue(fromEmptyIds.isEmpty(), 'An empty Id set must produce an empty index');
    }

    /**
     * Captures carrying no RFC identifiers at all (the platform allows both fields to be
     * blank) must short-circuit BEFORE the anchor query. An unbounded
     * `Thread_Key__c IN :()` read is the shape that turns a selective External-Id lookup
     * into a table scan.
     */
    @isTest
    static void index_capturesWithNoIdentifiers_skipTheAnchorQuery() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT, null);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ buildCapture(null, null) });
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        Assert.isTrue(anchors.isEmpty(),
            'A capture with no identifiers can match no anchor');
        Assert.areEqual(queriesBefore, queriesAfter,
            'and it must not spend a query finding that out — an anchor read with an empty '
            + 'bind set is the non-selective shape this short-circuit exists to prevent');
    }

    /**
     * `isAnchoredOn` is called by the guard for every related Lead AND for the
     * `RelatedToId` record, which is frequently null. Null arguments and unknown records
     * must be a plain false, never an exception inside the guard decision loop.
     */
    @isTest
    static void isAnchoredOn_nullOrUnknownRecord_isFalse() {
        Lead broker = TestDataFactory.createLead(true);
        insert anchorOnWho(broker.Id, DEAL_ROOT, null);
        EmailMessage capture = buildCapture(DEAL_ROOT, DEAL_ROOT);

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.isFalse(anchors.isAnchoredOn(null, capture),
            'A null record Id (the usual state of RelatedToId) must be false, not a throw');
        Assert.isFalse(anchors.isAnchoredOn(broker.Id, null),
            'A null message must be false, not a throw');
        Assert.isFalse(anchors.isAnchoredOn(UserInfo.getUserId(), capture),
            'A record carrying no anchors must be false');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // isMessageIdAnchoredOn — the third accessor (added 2026-08-04, guard 5)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE CONTRACT THIS ACCESSOR EXISTS TO ENFORCE. A reply-anchor Task's
     * `Thread_Key__c` (the thread ROOT) must satisfy `isAnchoredOn`'s union but must
     * NOT satisfy this Message-ID-only accessor — only `Inbound_Message_Id__c` (THIS
     * message's own id) may. Both are asserted against the SAME index in the SAME
     * test so the contrast is proven in one pass, not inferred across two.
     */
    @isTest
    static void isMessageIdAnchoredOn_matchesOnlyExactMessageId_notTheThreadKey() {
        Lead broker = TestDataFactory.createLead(true);
        String ownMessageId = 'anchor-own-id@mail.example.invalid';
        insert new Task(WhoId = broker.Id, Subject = 'Email: deal', Status = 'Completed',
                        TaskSubtype = 'Email', Thread_Key__c = DEAL_ROOT,
                        Inbound_Message_Id__c = ownMessageId);

        EmailMessage threadRootMatchOnly = buildCapture(DEAL_ROOT, 'unrelated@mail.example.invalid');
        EmailMessage exactMessageIdMatch =
            buildCapture('unrelated-thread@mail.example.invalid', ownMessageId);

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors = EmailThreadAnchorService.index(
            new List<EmailMessage>{ threadRootMatchOnly, exactMessageIdMatch });
        Test.stopTest();

        Assert.isTrue(anchors.isAnchoredOn(broker.Id, threadRootMatchOnly),
            'Precondition: the union test (isAnchoredOn) DOES match via the thread root — this '
            + 'is the normal state of every reply, and the test proves nothing if the union '
            + 'misses it too');
        Assert.isFalse(anchors.isMessageIdAnchoredOn(broker.Id, threadRootMatchOnly),
            'A Thread-Key-only match must NOT satisfy the Message-ID-only accessor — reusing '
            + 'isAnchoredOn\'s union here would delete every EAC copy of every reply after the '
            + 'first one the pipeline logged, and every EAC copy of outbound mail sharing the '
            + 'thread root');
        Assert.isTrue(anchors.isMessageIdAnchoredOn(broker.Id, exactMessageIdMatch),
            'A capture whose OWN MessageIdentifier equals the anchor\'s Inbound_Message_Id__c '
            + 'must satisfy the accessor');
    }

    /**
     * ⚠ SPLIT 2026-08-04 (code review) — the original single test here, named
     * "...isBracketAgnosticInBothDirections", covered only THIS direction and did not
     * actually exercise `isMessageIdAnchoredOn`'s own `normalize(message.MessageIdentifier)`
     * call: anchor-side normalization happens once, in `index(...)`, when the Task row is
     * folded into `messageIdsByRecordId` — so by the time this accessor runs, the stored
     * value is ALREADY bare regardless of whether it arrived bracketed. Pairing that with a
     * capture whose own MessageIdentifier is ALREADY bare means `normalize(bareId)` is a
     * no-op either way, so deleting the accessor's own `normalize(...)` call (production
     * line `EmailThreadAnchorService.cls:198`) would leave this test green. See the mirror
     * test below, which is the direction that actually catches that mutation.
     *
     * This test alone proves: a BRACKETED-at-rest Task field still normalizes correctly
     * through the `index(...)` build path (the P4 fix), and a bare capture value matches it.
     */
    @isTest
    static void isMessageIdAnchoredOn_bracketedAnchorAtRestMatchesABareCapture() {
        Lead broker = TestDataFactory.createLead(true);
        String bareId = 'bracket-agnostic@mail.example.invalid';
        // Stored BRACKETED, as the raw Message-ID header arrives.
        insert new Task(WhoId = broker.Id, Subject = 'Email: deal', Status = 'Completed',
                        TaskSubtype = 'Email', Inbound_Message_Id__c = '<' + bareId + '>');
        // EAC supplies the BARE form.
        EmailMessage capture = buildCapture(null, bareId);

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.isTrue(anchors.isMessageIdAnchoredOn(broker.Id, capture),
            'A BRACKETED-at-rest stored anchor must match a BARE capture MessageIdentifier — '
            + 'the same P4 normalization isAnchoredOn relies on must protect this accessor '
            + 'too (exercises index()\'s anchor-side normalize, not the accessor\'s own)');
    }

    /**
     * The MIRROR direction, added 2026-08-04 (code review) alongside the split above —
     * this is the one that actually exercises `isMessageIdAnchoredOn`'s OWN
     * `normalize(message.MessageIdentifier)` call. The stored anchor is bare (so
     * `index(...)`'s own normalization is a no-op and cannot be masking anything), and the
     * CAPTURE supplies the bracketed form. If the accessor's own `normalize(...)` call
     * (`EmailThreadAnchorService.cls:198`) were ever deleted, `messageId` would stay
     * bracketed and fail to match the bare stored value — this assertion goes red exactly
     * there. `bracketAsymmetryIsClosedByNormalization` (line ~93) already covers this same
     * stored-bare/capture-bracketed direction for `isAnchoredOn`; this is that direction's
     * first coverage for `isMessageIdAnchoredOn`.
     */
    @isTest
    static void isMessageIdAnchoredOn_bareAnchorAtRestMatchesABracketedCapture() {
        Lead broker = TestDataFactory.createLead(true);
        String bareId = 'bracket-agnostic-mirror@mail.example.invalid';
        // Stored BARE on purpose — real Inbound_Message_Id__c rows are bracketed (measured
        // E3, class header), but that would let index()'s own anchor-side normalize() mask
        // a broken accessor-side normalize(). Bare-at-rest isolates the accessor's own call.
        insert new Task(WhoId = broker.Id, Subject = 'Email: deal', Status = 'Completed',
                        TaskSubtype = 'Email', Inbound_Message_Id__c = bareId);
        // EAC supplies the BRACKETED form.
        EmailMessage capture = buildCapture(null, '<' + bareId + '>');

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.isTrue(anchors.isMessageIdAnchoredOn(broker.Id, capture),
            'A BARE stored anchor must match a BRACKETED capture MessageIdentifier — this is '
            + 'the direction that actually proves isMessageIdAnchoredOn normalizes the '
            + 'capture side itself, not merely inheriting index()\'s anchor-side pass');
    }

    /**
     * The membership test must be per-record, not "does this Message-ID exist
     * anywhere". The same identifier anchored on Lead A must not satisfy a query
     * about Lead B — a global test here would let guard 5 delete a capture off a
     * record that never received the pipeline row.
     */
    @isTest
    static void isMessageIdAnchoredOn_isRecordScoped() {
        Lead leadA = TestDataFactory.createLead(true);
        Lead leadB = TestDataFactory.createLead(true);
        String messageId = 'record-scoped@mail.example.invalid';
        insert anchorOnWho(leadA.Id, null, messageId);
        EmailMessage capture = buildCapture(null, messageId);

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.isTrue(anchors.isMessageIdAnchoredOn(leadA.Id, capture),
            'Precondition: the anchor IS found on Lead A');
        Assert.isFalse(anchors.isMessageIdAnchoredOn(leadB.Id, capture),
            'The same Message-ID anchored on Lead A must not satisfy a query about a DIFFERENT '
            + 'record');
    }

    /**
     * `isMessageIdAnchoredOn` is called by the guard for every related Lead AND for
     * the `RelatedToId` record, which is frequently null. Null arguments and unknown
     * records must be a plain false, never an exception inside the guard's delete
     * decision.
     */
    @isTest
    static void isMessageIdAnchoredOn_nullOrUnknownRecord_isFalse() {
        Lead broker = TestDataFactory.createLead(true);
        String messageId = 'null-safety@mail.example.invalid';
        insert anchorOnWho(broker.Id, null, messageId);
        EmailMessage capture = buildCapture(null, messageId);

        Test.startTest();
        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(new List<EmailMessage>{ capture });
        Test.stopTest();

        Assert.isFalse(anchors.isMessageIdAnchoredOn(null, capture),
            'A null record Id (the usual state of RelatedToId) must be false, not a throw');
        Assert.isFalse(anchors.isMessageIdAnchoredOn(broker.Id, null),
            'A null message must be false, not a throw');
        Assert.isFalse(anchors.isMessageIdAnchoredOn(UserInfo.getUserId(), capture),
            'A record carrying no anchors must be false');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * An UNSAVED capture in the shape EAC materializes. Unsaved is deliberate — the
     * record-taking `index` overload never touches the database, so most tests here need
     * no EmailMessage DML at all.
     *
     * @param threadId  RFC Message-ID of the thread root; nullable.
     * @param messageId RFC Message-ID of this message; nullable.
     * @return The unsaved EmailMessage.
     */
    private static EmailMessage buildCapture(String threadId, String messageId) {
        return new EmailMessage(
            Subject = 'captured',
            Status = '3',
            Incoming = false,
            ThreadIdentifier = threadId,
            MessageIdentifier = messageId,
            FromAddress = 'junior@example.invalid',
            ToAddress = 'anchor.broker@example.invalid'
        );
    }

    /**
     * An unsaved pipeline thread anchor sitting on a WHO (Lead or Contact) — the
     * pre-conversion shape InboundEmailActivityService writes.
     *
     * ⚠ Task.Type is deliberately absent and must stay absent: it does not exist in this
     * org, compiles anyway, and throws at runtime (see InboundEmailActivityService).
     *
     * @param whoId     Lead or Contact the anchor sits on.
     * @param threadKey Conversation-root Message-ID; nullable.
     * @param messageId This message's own Message-ID; nullable.
     * @return The unsaved anchor Task.
     */
    private static Task anchorOnWho(Id whoId, String threadKey, String messageId) {
        return new Task(
            WhoId = whoId,
            Subject = 'Email: deal',
            Status = 'Completed',
            TaskSubtype = 'Email',
            Thread_Key__c = threadKey,
            Inbound_Message_Id__c = messageId
        );
    }

    /**
     * An unsaved pipeline thread anchor sitting on a WHAT — the post-conversion shape,
     * which experiment E1 showed standard conversion produces by itself, and the only
     * shape the resolution chain acts on.
     *
     * @param whatId    The Opportunity (or other record) the anchor sits on.
     * @param threadKey Conversation-root Message-ID; nullable.
     * @param messageId This message's own Message-ID; nullable.
     * @return The unsaved anchor Task.
     */
    private static Task anchorOnWhat(Id whatId, String threadKey, String messageId) {
        return new Task(
            WhatId = whatId,
            Subject = 'Email: deal',
            Status = 'Completed',
            TaskSubtype = 'Email',
            Thread_Key__c = threadKey,
            Inbound_Message_Id__c = messageId
        );
    }
}
