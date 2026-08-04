/**
 * Test class for InboundEmailActivityService — the Task-write layer of the Broker-Protection
 * inbound-email pipeline. NEW as of 2026-08-04, created alongside the sender-name/sender-email
 * signature change: both `logInboundEmail` overloads gained `senderName`/`senderEmail` as their
 * final two parameters, and the old 6-argument (sender-less) overloads were REMOVED outright
 * rather than kept alongside the new ones — so every existing caller had to be updated, and any
 * future caller cannot silently regress to a sender-less Task.
 *
 * WHY THIS CLASS HAD NO DIRECT TEST BEFORE. Before 2026-08-04 it was covered only INDIRECTLY,
 * through ExtractAddressQueueableTest's end-to-end Task assertions (WhoId, Inbound_Message_Id__c,
 * Thread_Key__c) — see the persistent memory note "Broker Protection Phase 3 staging model",
 * "Coverage gap found, NOT filled". This file closes that gap for InboundEmailActivityService
 * specifically: every branch of buildSubject / buildDescription / attachTo is now exercised
 * directly, without needing to drive the whole routing tree and an LLM mock just to observe a
 * Task field.
 *
 * ⚠ Task.Type IS NEVER QUERIED OR ASSERTED IN THIS CLASS, AND MUST NOT BE. Per this org's own
 * template (see the class-under-test's header, "THE REAL CAUSE"), Task.Type does not exist in
 * FieldDefinition here: a reference to it COMPILES (the Apex compiler resolves it against the
 * standard object schema, not this org's actual field set) but THROWS AT RUNTIME —
 * "Operation failed due to fields being inaccessible on Sobject Task" — on both a SOQL SELECT and
 * a DML read-back. So "Type is never set" cannot be positively queried here; it is instead proven
 * NEGATIVELY, by construction: every test below inserts one or more Tasks through logInboundEmail
 * and asserts on the result, and if that method ever started setting Type, the INSERT ITSELF would
 * throw in this org and every single test in this class would fail. Do not "complete" any test
 * here with a `SELECT Type FROM Task` — it will not behave the way a naive reviewer expects.
 *
 * ⚠ 251-RECORD BULK MANDATE (.claude/rules/bulk-test-rule.md) — WHY IT DOES NOT APPLY HERE, AND
 * WHAT REPLACES IT. InboundEmailActivityService is a plain synchronous service — no Queueable, no
 * trigger, no System.enqueueJob of its own — so the rule's per-transaction-singleton ASYNC
 * exemption does not literally name it. But a literal 251-target call is still IMPOSSIBLE to
 * produce honestly, for a reason specific to this class rather than borrowed from its caller:
 * `logInboundEmail(List&lt;Id&gt;, ...)` is invoked from exactly ONE call site —
 * `ExtractAddressQueueable.finish()` — with the DISTINCT ROUTED RECORDS from a SINGLE inbound
 * email's routing tree, which is hard-capped at `ExtractAddressQueueable.MAX_PROPERTIES` = 10 (a
 * bound that class's own header justifies: System.enqueueJob caps at 50 jobs/transaction, and the
 * per-property SOQL footprint exhausts the async 200-query governor limit at roughly 14–24
 * properties). A test that fabricated a 251-element target list would prove nothing about a shape
 * production can never produce — exactly the anti-pattern the bulk-test-rule exemption exists to
 * avoid (see also ExtractAddressQueueableTest's own header for the identical reasoning applied to
 * the caller). The replacement is `logInboundEmail_tenDistinctTargets_isExactlyOneDmlAndAddsNoSoql`
 * below: a MAX_PROPERTIES-scale (10-target) call asserting EXACTLY one DML statement and ZERO
 * added SOQL — the actual invariant a future regression could break.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes in this module
 * (PropertyClaimServiceTest, PropertyMatchingServiceTest, ExtractAddressQueueableTest).
 *
 * @author Unit Testing Agent
 */
@isTest
private class InboundEmailActivityServiceTest {

    // ═════════════════════════════════════════════════════════════════════════
    // SUBJECT COMPOSITION — buildSubject, exercised through the public overloads
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void logInboundEmail_normalSenderAndSubject_prefixesSubjectAndAttachesViaWhoId() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Gordon Center - Jacksonville FL', 'body text',
            'msg-normal-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Subject, WhoId, WhatId FROM Task
            WHERE Inbound_Message_Id__c = 'msg-normal-1@example.invalid'
        ];
        Assert.areEqual('From Jane Broker: Gordon Center - Jacksonville FL', logged.Subject,
            'The normal case should prefix the sender name, colon-separated, ahead of the original subject');
        Assert.areEqual(target.Id, logged.WhoId, 'A Lead target must attach via WhoId');
        Assert.isNull(logged.WhatId, 'and never via WhatId');
    }

    @isTest
    static void logInboundEmail_nameBlankAddressKnown_addressBecomesTheLabel() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, '100 Fallback St', 'body text',
            'msg-nameblank-1@example.invalid', null, null,
            '', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Subject FROM Task WHERE Inbound_Message_Id__c = 'msg-nameblank-1@example.invalid'
        ];
        Assert.areEqual('From jane@brokerfirm.example.invalid: 100 Fallback St', logged.Subject,
            'When the name is blank, the address must become the sender label');
    }

    @isTest
    static void logInboundEmail_bothSenderFieldsBlank_omitsThePrefixEntirely() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'No Sender Known Subject', 'body text',
            'msg-bothblank-1@example.invalid', null, null,
            null, null);
        Test.stopTest();

        Task logged = [
            SELECT Subject FROM Task WHERE Inbound_Message_Id__c = 'msg-bothblank-1@example.invalid'
        ];
        Assert.areEqual('No Sender Known Subject', logged.Subject,
            'With no sender resolved on either path, the Subject must be BYTE-IDENTICAL to the '
            + 'pre-2026-08-04 bare subject — no dangling "From : " and no noisy "From (unknown): "');
        Assert.isFalse(logged.Subject.startsWith('From '), 'No prefix token of any kind should appear');
    }

    @isTest
    static void logInboundEmail_blankSubjectKnownSender_usesTheSubjectFallbackAfterThePrefix() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, '', 'body text',
            'msg-blanksubj-known-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Subject FROM Task WHERE Inbound_Message_Id__c = 'msg-blanksubj-known-1@example.invalid'
        ];
        Assert.areEqual('From Jane Broker: (no subject)', logged.Subject,
            'A blank subject must substitute the fallback text INSIDE the composition, never leaving '
            + 'a trailing "From Jane Broker: " with nothing after it');
    }

    @isTest
    static void logInboundEmail_blankSubjectNoSender_isTheBareFallback() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, null, 'body text',
            'msg-blanksubj-none-1@example.invalid', null, null,
            null, null);
        Test.stopTest();

        Task logged = [
            SELECT Subject FROM Task WHERE Inbound_Message_Id__c = 'msg-blanksubj-none-1@example.invalid'
        ];
        Assert.areEqual('(no subject)', logged.Subject,
            'A blank subject AND no sender should yield the bare fallback text with no prefix at all');
    }

    @isTest
    static void logInboundEmail_whitespaceOnlySenderValues_fallThroughLikeBlank() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Whitespace Sender Test', 'body text',
            'msg-whitespace-1@example.invalid', null, null,
            '   ', '   ');
        Test.stopTest();

        Task logged = [
            SELECT Subject FROM Task WHERE Inbound_Message_Id__c = 'msg-whitespace-1@example.invalid'
        ];
        Assert.areEqual('Whitespace Sender Test', logged.Subject,
            'String.isBlank treats whitespace-only values as blank, so a whitespace-only name AND '
            + 'address must fall all the way through to the no-prefix case, exactly like nulls');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TRUNCATION — the load-bearing claim: the sender survives, the subject's TAIL does not
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void logInboundEmail_longNameAndLongSubject_truncatesTo255WithSenderIntact() {
        Lead target = TestDataFactory.createLead(true);
        String longName = 'N'.repeat(300);
        // ⚠ NOT A UNIFORM-CHARACTER STRING, DELIBERATELY. 'S'.repeat(300) made
        // longSubject.startsWith(survivingSubject) VACUOUS: every 188-char slice of an
        // all-identical-character string satisfies startsWith, so head-preserving, tail-preserving
        // and middle-preserving clips would all have passed this assertion identically. A
        // discriminating head/tail marker is what makes the assertion below actually capable of
        // failing if the clip ever stopped being head-preserving.
        String longSubject = 'HEAD_' + 'S'.repeat(290) + '_TAIL';

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, longSubject, 'body text',
            'msg-truncate-1@example.invalid', null, null,
            longName, null);
        Test.stopTest();

        Task logged = [
            SELECT Subject FROM Task WHERE Inbound_Message_Id__c = 'msg-truncate-1@example.invalid'
        ];
        Assert.areEqual(255, logged.Subject.length(),
            'A 300-char name plus a 300-char subject must be clipped to EXACTLY the Subject field length');

        String expectedPrefix = 'From ' + longName.substring(0, 60) + ': ';
        Assert.isTrue(logged.Subject.startsWith(expectedPrefix),
            'THE LOAD-BEARING CLAIM: the sender must survive INTACT at the head of the Subject even '
            + 'when the combined length overflows 255 — this is the whole reason the sender is clipped '
            + 'to 60 chars BEFORE the composed string is clipped to 255. Actual: ' + logged.Subject);

        String survivingSubject = logged.Subject.substring(expectedPrefix.length());
        Assert.isTrue(survivingSubject.length() >= 188,
            'At least 188 characters of the original subject must survive the 255-char clip '
            + '(255 total - a 67-char worst-case prefix cost = 188). Actual surviving length: '
            + survivingSubject.length());
        Assert.isTrue(survivingSubject.startsWith('HEAD_'),
            'The surviving portion must be the HEAD of the original subject — clip is head-preserving. '
            + 'Actual surviving portion: ' + survivingSubject);
        Assert.isFalse(survivingSubject.contains('_TAIL'),
            'THE LOAD-BEARING CLAIM, DISCRIMINATING: what is lost must be the subject\'s TAIL, never '
            + 'its head — a tail- or middle-preserving clip would still show HEAD_ here, so the '
            + 'absence of _TAIL is what actually proves the clip drops the end, not the start. '
            + 'Actual surviving portion: ' + survivingSubject);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // DESCRIPTION COMPOSITION — buildDescription
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void logInboundEmail_normalCase_descriptionCarriesHeaderBlockThenBody() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Gordon Center - Jacksonville FL', 'Pitching this asset, see attached.',
            'msg-desc-normal-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Description FROM Task WHERE Inbound_Message_Id__c = 'msg-desc-normal-1@example.invalid'
        ];
        Assert.isTrue(logged.Description.contains('From: Jane Broker <jane@brokerfirm.example.invalid>'),
            'The header block must show the name and address together, RFC-shaped');
        Assert.isTrue(logged.Description.contains('Subject: Gordon Center - Jacksonville FL'),
            'The header block must carry the original subject on its own RFC-shaped line');
        Assert.isTrue(logged.Description.contains('-'.repeat(60)),
            'The 60-hyphen rule must close the header block');
        Assert.isTrue(logged.Description.endsWith('Pitching this asset, see attached.'),
            'The raw body must follow the header, beneath a blank line');
    }

    @isTest
    static void logInboundEmail_nameOnlyAddressOnlyAndNeither_threeMoreFromLineShapes() {
        // The FOURTH shape (name + address together) is already pinned by
        // logInboundEmail_normalCase_descriptionCarriesHeaderBlockThenBody above; this test covers
        // the three remaining ones.
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Name only', 'body',
            'msg-desc-nameonly-1@example.invalid', null, null,
            'Jane Broker', null);
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Address only', 'body',
            'msg-desc-addressonly-1@example.invalid', null, null,
            null, 'jane@brokerfirm.example.invalid');
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Neither', 'body',
            'msg-desc-neither-1@example.invalid', null, null,
            null, null);
        Test.stopTest();

        Assert.isTrue([
            SELECT Description FROM Task WHERE Inbound_Message_Id__c = 'msg-desc-nameonly-1@example.invalid'
        ].Description.contains('From: Jane Broker\n'),
            'Name only must render the bare name on the From: line, no angle brackets');
        Assert.isTrue([
            SELECT Description FROM Task WHERE Inbound_Message_Id__c = 'msg-desc-addressonly-1@example.invalid'
        ].Description.contains('From: jane@brokerfirm.example.invalid\n'),
            'Address only must render the bare address on the From: line');
        Assert.isTrue([
            SELECT Description FROM Task WHERE Inbound_Message_Id__c = 'msg-desc-neither-1@example.invalid'
        ].Description.contains('From: (sender not identified)\n'),
            'Neither known must still emit the From: line — its own absence is information the reader needs');
    }

    @isTest
    static void logInboundEmail_longSubjectTruncatedInTaskSubject_descriptionCarriesTheFullUntruncatedSubject() {
        // Deliberately a NORMAL-length sender name here (not the 300-char one the dedicated
        // truncation test above uses): the point of THIS test is that even an ordinary, short
        // sender prefix is enough to push a 300-char subject past the 255-char Subject field, and
        // the Description must still carry the subject in full regardless of the sender's length.
        Lead target = TestDataFactory.createLead(true);
        String longSubject = 'S'.repeat(300);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, longSubject, 'short body',
            'msg-desc-longsubj-1@example.invalid', null, null,
            'Jane Broker', null);
        Test.stopTest();

        Task logged = [
            SELECT Subject, Description FROM Task
            WHERE Inbound_Message_Id__c = 'msg-desc-longsubj-1@example.invalid'
        ];
        Assert.areEqual(255, logged.Subject.length(),
            'Precondition: the Task Subject must actually be truncated, or this test proves nothing '
            + 'about the guarantee below');
        Assert.isFalse(logged.Subject.contains(longSubject),
            'Precondition: the full subject must NOT fit in the (truncated) Subject field');

        Assert.isTrue(logged.Description.contains('Subject: ' + longSubject),
            'The Description\'s Subject: line must carry the FULL, UNTRUNCATED original subject even '
            + 'though the Subject FIELD truncated it — this is what makes the truncation trade safe');
    }

    @isTest
    static void logInboundEmail_nullBody_descriptionIsHeaderOnlyWithNoLiteralNullText() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'No body at all', null,
            'msg-desc-nullbody-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Description FROM Task WHERE Inbound_Message_Id__c = 'msg-desc-nullbody-1@example.invalid'
        ];
        Assert.isFalse(logged.Description.contains('null'),
            'A null body must NEVER render the literal text "null" — Apex string concatenation of a '
            + 'null operand does that unless explicitly guarded. Actual: [' + logged.Description + ']');

        // ⚠ MEASURED 2026-08-04 (dry-run 0Afiw000000EPszCAG): Task.Description STRIPS TRAILING
        // WHITESPACE on save — the stored value ends at the 60th hyphen with no trailing newline,
        // even though buildDescription emits one (header + '\n' + '' for an empty body). So the
        // expected value used for the startsWith comparison must NOT carry trailing whitespace of
        // its own — that is platform behaviour, not a property of the composer, and asserting it
        // would make the test depend on something buildDescription does not control.
        String expectedHeader = 'From: Jane Broker <jane@brokerfirm.example.invalid>\n'
            + 'Subject: No body at all\n' + '-'.repeat(60);
        Assert.isTrue(logged.Description.startsWith(expectedHeader),
            'The Description must start with the composed header block. Actual: [' + logged.Description + ']');
        Assert.areEqual(expectedHeader, logged.Description.trim(),
            'A null body must yield the header and nothing else');
    }

    @isTest
    static void logInboundEmail_blankBody_descriptionIsHeaderOnlyWithNoLiteralNullText() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'No body at all', '',
            'msg-desc-blankbody-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Description FROM Task WHERE Inbound_Message_Id__c = 'msg-desc-blankbody-1@example.invalid'
        ];
        Assert.isFalse(logged.Description.contains('null'),
            'An empty-string body must also never render "null". Actual: [' + logged.Description + ']');
    }

    @isTest
    static void logInboundEmail_hugeBody_the32000ClipDropsTheBodyTailNotTheHeader() {
        Lead target = TestDataFactory.createLead(true);
        String hugeBody = 'B'.repeat(40000);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Huge body test', hugeBody,
            'msg-desc-huge-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Description FROM Task WHERE Inbound_Message_Id__c = 'msg-desc-huge-1@example.invalid'
        ];

        String expectedHeader = 'From: Jane Broker <jane@brokerfirm.example.invalid>\n'
            + 'Subject: Huge body test\n'
            + '-'.repeat(60) + '\n';
        String expectedFullBeforeClip = expectedHeader + '\n' + hugeBody;
        Assert.isTrue(expectedFullBeforeClip.length() > 32000,
            'Precondition: the combined header + body must exceed the field length, or this test '
            + 'proves nothing about truncation');

        Assert.areEqual(32000, logged.Description.length(),
            'The composed Description must be clipped to EXACTLY the field length');
        Assert.areEqual(expectedFullBeforeClip.substring(0, 32000), logged.Description,
            'The 32,000-char clip must be HEAD-PRESERVING: the header (and the blank line after it) '
            + 'survive intact, and only the BODY\'S TAIL is dropped');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // INVARIANTS UNCHANGED BY THE SENDER-NAME CHANGE
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void logInboundEmail_messageIdAndThreadKeyAndSubtype_areUnaffectedBySenderFields() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Threading check', 'body',
            'msg-thread-root@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Inbound_Message_Id__c, Thread_Key__c, TaskSubtype, Status
            FROM Task WHERE Inbound_Message_Id__c = 'msg-thread-root@example.invalid'
        ];
        Assert.areEqual('msg-thread-root@example.invalid', logged.Inbound_Message_Id__c,
            'Inbound_Message_Id__c must be completely unaffected by the sender-name change');
        Assert.areEqual('msg-thread-root@example.invalid', logged.Thread_Key__c,
            'With no In-Reply-To/References, the thread key must still be this message\'s own id');
        Assert.areEqual('Email', logged.TaskSubtype, 'TaskSubtype must still render as Email');
        Assert.areEqual('Completed', logged.Status, 'Status must still be Completed');
    }

    @isTest
    static void logInboundEmail_withReplyHeaders_threadKeyStillDerivedFromReferences() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Reply', 'body',
            'msg-child-1@example.invalid',
            '<root-99@example.invalid>',
            '<root-99@example.invalid> <mid-1@example.invalid>',
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT Thread_Key__c FROM Task WHERE Inbound_Message_Id__c = 'msg-child-1@example.invalid'
        ];
        Assert.areEqual('root-99@example.invalid', logged.Thread_Key__c,
            'Thread_Key__c must still derive from References\' FIRST Message-ID, unaffected by the '
            + 'new sender parameters');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // isAlreadyLogged
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void isAlreadyLogged_afterLogging_returnsTrueForThatMessageIdAndFalseForAnother() {
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'subj', 'body', 'msg-already-logged-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Assert.isTrue(InboundEmailActivityService.isAlreadyLogged('msg-already-logged-1@example.invalid'),
            'A Task carrying this exact Message-ID must be found');
        Assert.isFalse(InboundEmailActivityService.isAlreadyLogged('msg-never-logged-1@example.invalid'),
            'An unrelated Message-ID must not be reported as already logged');
    }

    @isTest
    static void isAlreadyLogged_blankMessageId_returnsFalse() {
        Assert.isFalse(InboundEmailActivityService.isAlreadyLogged(null),
            'A null Message-ID must never report as already logged');
        Assert.isFalse(InboundEmailActivityService.isAlreadyLogged(''),
            'A blank Message-ID must never report as already logged');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // MULTI-TARGET OVERLOAD — one Task per record, ONE bulk DML, C-3 ascending-priority order
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void logInboundEmail_multipleTargets_insertsOneTaskPerRecordInOneDmlPreservingOrder() {
        List<Lead> targets = TestDataFactory.createLeads(3, true);
        List<Id> orderedTargets = new List<Id>{ targets[0].Id, targets[1].Id, targets[2].Id };

        // Deliberately NOT wrapped in Test.startTest()/stopTest(): this is a purely synchronous
        // call with no async component, and capturing Limits deltas directly around it is simpler
        // and unambiguous — there is no "stopTest restores the pre-test counters" trap to avoid
        // here, because nothing async is ever queued by this method.
        Integer dmlBefore = Limits.getDmlStatements();
        List<Task> inserted = InboundEmailActivityService.logInboundEmail(
            orderedTargets, 'Multi-target subject', 'body',
            'msg-multitarget-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Integer dmlAfter = Limits.getDmlStatements();

        Assert.areEqual(1, dmlAfter - dmlBefore,
            'N Tasks sharing one Message-ID must be inserted in exactly ONE bulk DML statement, not one per target');
        Assert.areEqual(3, inserted.size(), 'One Task must be returned per target record, in the same order');

        List<Task> logged = [
            SELECT Id, WhoId FROM Task
            WHERE Inbound_Message_Id__c = 'msg-multitarget-1@example.invalid'
            ORDER BY Id ASC
        ];
        Assert.areEqual(3, logged.size(), 'Exactly one Task per distinct routed record');
        Assert.areEqual(orderedTargets[0], logged[0].WhoId,
            'The FIRST-inserted Task (lowest Id) must belong to the FIRST (lowest-priority) target');
        Assert.areEqual(orderedTargets[1], logged[1].WhoId, 'The middle Task belongs to the middle target');
        Assert.areEqual(orderedTargets[2], logged[2].WhoId,
            'C-3: the HIGHEST-priority target must be inserted LAST, so it receives the HIGHEST Id — '
            + 'that is exactly what TaskSelector\'s CreatedDate DESC, Id DESC tie-break relies on to '
            + 'land a later reply on the deal DPEG actually owns rather than an arbitrary co-routed record');
        Assert.isTrue(logged[0].Id < logged[1].Id && logged[1].Id < logged[2].Id,
            'Ascending Id order must exactly mirror the ascending-priority input order');
    }

    @isTest
    static void logInboundEmail_nullOrEmptyTargetList_insertsOneUnattachedTask() {
        Test.startTest();
        List<Task> insertedFromNull = InboundEmailActivityService.logInboundEmail(
            (List<Id>) null, 'No targets (null list)', 'body',
            'msg-null-targets-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        List<Task> insertedFromEmpty = InboundEmailActivityService.logInboundEmail(
            new List<Id>(), 'No targets (empty list)', 'body',
            'msg-empty-targets-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Assert.areEqual(1, insertedFromNull.size(), 'A null target list must still insert exactly one unattached Task');
        Assert.areEqual(1, insertedFromEmpty.size(), 'An empty target list must still insert exactly one unattached Task');

        Task fromNull = [
            SELECT WhoId, WhatId FROM Task WHERE Inbound_Message_Id__c = 'msg-null-targets-1@example.invalid'
        ];
        Assert.isNull(fromNull.WhoId, 'An unattached Task (null target list) must carry no WhoId');
        Assert.isNull(fromNull.WhatId, 'An unattached Task (null target list) must carry no WhatId');

        Task fromEmpty = [
            SELECT WhoId, WhatId FROM Task WHERE Inbound_Message_Id__c = 'msg-empty-targets-1@example.invalid'
        ];
        Assert.isNull(fromEmpty.WhoId, 'An unattached Task (empty target list) must carry no WhoId');
        Assert.isNull(fromEmpty.WhatId, 'An unattached Task (empty target list) must carry no WhatId');

        // The Message-ID must still be recorded on the unattached row — that is what stops a
        // redelivery of a gated/pre-filtered email from re-running the whole routing tree.
        Assert.isTrue(InboundEmailActivityService.isAlreadyLogged('msg-null-targets-1@example.invalid'),
            'An unattached Task still counts for idempotency purposes');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // attachTo — WhoId (Lead / Contact) vs WhatId (everything else)
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void logInboundEmail_contactTarget_attachesViaWhoId() {
        Contact target = TestDataFactory.createContact(null, true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Contact target', 'body',
            'msg-contact-whoid-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT WhoId, WhatId FROM Task WHERE Inbound_Message_Id__c = 'msg-contact-whoid-1@example.invalid'
        ];
        Assert.areEqual(target.Id, logged.WhoId, 'A Contact target must attach via WhoId, exactly like a Lead');
        Assert.isNull(logged.WhatId, 'and never via WhatId');
    }

    @isTest
    static void logInboundEmail_nonLeadContactTarget_attachesViaWhatId() {
        Opportunity target = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        InboundEmailActivityService.logInboundEmail(
            target.Id, 'Opportunity target', 'body',
            'msg-whatid-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');
        Test.stopTest();

        Task logged = [
            SELECT WhoId, WhatId FROM Task WHERE Inbound_Message_Id__c = 'msg-whatid-1@example.invalid'
        ];
        Assert.areEqual(target.Id, logged.WhatId, 'A non-Lead/Contact target (e.g. a converted-winner Opportunity) must attach via WhatId');
        Assert.isNull(logged.WhoId, 'and never via WhoId');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // VOLUME / GOVERNOR HEADROOM — replaces the literal 251-record mandate (see class header)
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void logInboundEmail_tenDistinctTargets_isExactlyOneDmlAndAddsNoSoql() {
        // MAX_PROPERTIES-scale: the real ceiling ExtractAddressQueueable can ever pass to this
        // method in production, per the class header. Ten Leads stand in for ten distinct routed
        // records from one multi-property email.
        List<Lead> targets = TestDataFactory.createLeads(10, true);
        List<Id> orderedTargets = new List<Id>();
        for (Lead target : targets) {
            orderedTargets.add(target.Id);
        }

        // No Test.startTest()/stopTest() — see the ordering test above for why: this is a plain
        // synchronous call, and reading Limits directly around it is the unambiguous way to
        // measure its true incremental cost.
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        List<Task> inserted = InboundEmailActivityService.logInboundEmail(
            orderedTargets, 'Ten-target volume test', 'body',
            'msg-tenvolume-1@example.invalid', null, null,
            'Jane Broker', 'jane@brokerfirm.example.invalid');

        Assert.areEqual(0, Limits.getQueries() - queriesBefore,
            'logInboundEmail performs NO SOQL of its own — computeThreadKey and both composers are '
            + 'pure functions over already-known values');
        Assert.areEqual(1, Limits.getDmlStatements() - dmlBefore,
            'Ten Tasks sharing one Message-ID must still be exactly ONE bulk DML statement, never one per target');
        Assert.areEqual(10, inserted.size(), 'One Task per target must be returned');
        Assert.areEqual(10, [
            SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = 'msg-tenvolume-1@example.invalid'
        ], 'All ten Tasks must actually have been inserted');
    }
}
