@isTest
private class LeaseInquiryControllerTest {

    @testSetup static void setup() {
        Property__c pr = TestDataFactory.createProperty(true);
        Property_Asset__c pa = TestDataFactory.createPropertyAsset(pr.Id, false);
        pa.Name = 'Westgate Plaza';
        pa.Vacant_Area__c = 8000;
        insert pa;
        Contact bk = TestDataFactory.createBrokerContact(null, false);
        bk.LastName = 'Webb'; bk.Email = 'mw@x.com'; bk.Phone = '1'; bk.Broker_Firm__c = 'Lee & Associates';
        insert bk;
        // Insert fires the Stage Timer (sets Stage_Start_Date) and Open Log (creates 1 activity) flows.
        Lease_Inquiry__c inq = TestDataFactory.createLeaseInquiry(pa.Id, false);
        inq.Tenant_Name__c = 'Sunrise Cafe'; inq.Broker__c = bk.Id; inq.Space_Required__c = 1800;
        inq.Initial_Notes__c = 'Toured the end-cap; wants to move fast.';
        insert inq;
    }

    private static Lease_Inquiry__c theInquiry() {
        return [SELECT Id, Stage__c, Ball_In_Court__c, Status__c, Stage_Start_Date__c FROM Lease_Inquiry__c LIMIT 1];
    }

    @isTest static void openingEntryAndStageTimer() {
        Lease_Inquiry__c inq = theInquiry();
        System.assertEquals(Date.today(), inq.Stage_Start_Date__c, 'Stage Timer flow stamps today on create');
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(inq.Id);
        System.assertEquals(1, v.entries.size(), 'Open Log flow seeds one opening entry');
        System.assertEquals('Inquiry Received', v.stage);
        System.assertEquals('Landlord', v.ballInCourt);
        System.assertEquals(false, v.closed);
        System.assertEquals(true, v.canAdvance);
        System.assertEquals('LOI Received', v.nextStage);
        System.assertEquals('Toured the end-cap; wants to move fast.', v.entries[0].details);
    }

    @isTest static void addUpdateAppendsAndSetsBall() {
        Lease_Inquiry__c inq = theInquiry();
        Test.startTest();
        Id sameId = LeaseInquiryController.addUpdate(inq.Id, '  Countered at $30/sq ft  ', 'Tenant', false, false, null, null);
        Test.stopTest();
        System.assertEquals(inq.Id, sameId);
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(inq.Id);
        System.assertEquals(2, v.entries.size(), 'One entry appended to the opening entry');
        // Find the appended entry by content (ordering is by Entry_Date, which is
        // frozen and therefore not distinguishable within a test transaction).
        LeaseInquiryController.Entry appended;
        for (LeaseInquiryController.Entry e : v.entries) {
            if (e.details == 'Countered at $30/sq ft') {
                appended = e;
            }
        }
        System.assertNotEquals(null, appended, 'Appended entry is present and trimmed');
        System.assertEquals('Tenant', appended.ball);
        Lease_Inquiry__c after = theInquiry();
        System.assertEquals('Tenant', after.Ball_In_Court__c, 'Parent ball in court is updated');
        System.assertEquals('Inquiry Received', after.Stage__c, 'Stage unchanged when not advancing');
    }

    @isTest static void addUpdateAdvancesStage() {
        Lease_Inquiry__c inq = theInquiry();
        Test.startTest();
        LeaseInquiryController.addUpdate(inq.Id, 'LOI received, forwarded to landlord.', 'Landlord', true, false, null, null);
        Test.stopTest();
        Lease_Inquiry__c after = theInquiry();
        System.assertEquals('LOI Received', after.Stage__c, 'Stage advances to the next step');
        System.assertEquals(Date.today(), after.Stage_Start_Date__c, 'Stage Timer flow resets the timer on advance');
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(inq.Id);
        System.assertEquals(2, v.entries.size());
    }

    // ───────────────── Optional reminder Task ─────────────────

    @isTest static void addUpdateWithReminderCreatesTask() {
        Lease_Inquiry__c inq = theInquiry();
        Date due = Date.today().addDays(7);
        Test.startTest();
        LeaseInquiryController.addUpdate(
            inq.Id, 'Sent the redline back.', 'Tenant', false, true, '  Chase the signed LOI  ', due
        );
        Test.stopTest();
        List<Task> tasks = [
            SELECT Id, Subject, ActivityDate, WhatId, OwnerId, IsReminderSet
            FROM Task
            WHERE WhatId = :inq.Id
        ];
        System.assertEquals(1, tasks.size(), 'Exactly one reminder Task is created');
        System.assertEquals('Chase the signed LOI', tasks[0].Subject, 'Subject is the trimmed reminder name');
        System.assertEquals(due, tasks[0].ActivityDate, 'ActivityDate is the reminder date (Due Date)');
        System.assertEquals(inq.Id, tasks[0].WhatId, 'Task targets the inquiry, not the log entry');
        System.assertEquals(UserInfo.getUserId(), tasks[0].OwnerId, 'Task is owned by the logging user');
        System.assertEquals(false, tasks[0].IsReminderSet, 'No bell popup: IsReminderSet is deliberately left unset');
        // The log entry is still appended alongside the reminder.
        System.assertEquals(2, [SELECT COUNT() FROM Lease_Activity__c WHERE Lease_Inquiry__c = :inq.Id]);
        // CONTROL for addUpdateReminderDateOutOfRangeRollsBackCommittedWork below: this
        // asserts that for THIS payload shape (ball 'Tenant' + ticked reminder) the parent
        // update genuinely commits. Its sibling passes the same payload with only the date
        // changed, so the sibling's failure can only be the Task insert — the third DML.
        // Without this line the sibling's assertions would be satisfied just as well by a
        // failure at the FIRST DML, which is the false-green it exists to eliminate.
        System.assertEquals('Tenant', theInquiry().Ball_In_Court__c,
            'The parent update commits for this payload — the reminder path reaches DML #2');
    }

    @isTest static void addUpdateWithoutReminderCreatesNoTask() {
        Lease_Inquiry__c inq = theInquiry();
        Test.startTest();
        LeaseInquiryController.addUpdate(inq.Id, 'No reminder needed here.', 'Tenant', false, false, null, null);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :inq.Id], 'Unticked reminder creates no Task');
        System.assertEquals(2, [SELECT COUNT() FROM Lease_Activity__c WHERE Lease_Inquiry__c = :inq.Id]);
    }

    @isTest static void addUpdateReminderNullFlagCreatesNoTask() {
        Lease_Inquiry__c inq = theInquiry();
        Test.startTest();
        LeaseInquiryController.addUpdate(inq.Id, 'Reminder flag omitted.', 'Tenant', false, null, null, null);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :inq.Id], 'Null reminder flag creates no Task');
    }

    // The setup Open Log flow seeds one entry, so a rolled-back addUpdate leaves exactly 1.
    @isTest static void addUpdateReminderBlankNameRollsBackEntry() {
        Lease_Inquiry__c inq = theInquiry();
        Boolean threw = false;
        try {
            LeaseInquiryController.addUpdate(inq.Id, 'Blank reminder name.', 'Tenant', false, true, '   ', Date.today());
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'A ticked reminder with a blank name is rejected');
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :inq.Id], 'No Task survives the rollback');
        System.assertEquals(
            1, [SELECT COUNT() FROM Lease_Activity__c WHERE Lease_Inquiry__c = :inq.Id],
            'The log entry is rolled back with the Task — only the seeded opening entry remains'
        );
    }

    @isTest static void addUpdateReminderNullDateRollsBackEntry() {
        Lease_Inquiry__c inq = theInquiry();
        Boolean threw = false;
        try {
            LeaseInquiryController.addUpdate(inq.Id, 'Missing reminder date.', 'Tenant', false, true, 'Chase the LOI', null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'A ticked reminder with no date is rejected');
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :inq.Id], 'No Task survives the rollback');
        System.assertEquals(
            1, [SELECT COUNT() FROM Lease_Activity__c WHERE Lease_Inquiry__c = :inq.Id],
            'The log entry is rolled back with the Task — only the seeded opening entry remains'
        );
    }

    // Forces the *other* catch block (System.DmlException, not AuraHandledException).
    // Details__c is a LongTextArea(4000); a 4001-char value fails on the very first DML
    // (the Lease_Activity__c insert, before the parent update or Task are attempted), so
    // this exercises Database.rollback(sp) + the 'This update could not be saved.' wrap
    // without depending on any object validation rule (none exist on this object).
    @isTest static void addUpdateDetailsTooLongTriggersDmlExceptionWrap() {
        Lease_Inquiry__c inq = theInquiry();
        String tooLong = 'A'.repeat(4001);
        Boolean threw = false;
        Test.startTest();
        try {
            LeaseInquiryController.addUpdate(inq.Id, tooLong, 'Tenant', false, false, null, null);
            System.assert(false, 'Expected a DmlException-wrapped AuraHandledException for an over-length Details__c');
        } catch (AuraHandledException e) {
            threw = true;
            // This is the only assertion in this file that checks message CONTENT, which is
            // how the missing setMessage() defect was caught. Do not weaken it to `threw`.
            System.assertEquals(
                'This update could not be saved. Check your entry and try again, or contact your administrator.',
                e.getMessage(),
                'DmlException branch surfaces the fixed generic message via the ahe() helper'
            );
            // The raw platform text must not reach the user: an over-length LongTextArea
            // fails with a message naming the field and its limit. None of that may leak.
            String m = e.getMessage();
            System.assert(!m.contains('Details__c'), 'No field API name leaks to the user: ' + m);
            System.assert(!m.containsIgnoreCase('STRING_TOO_LONG'), 'No platform status code leaks to the user: ' + m);
            System.assert(!m.contains('4000'), 'No platform limit detail leaks to the user: ' + m);
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'An over-length Details__c is rejected by the platform, not silently truncated');
        System.assertEquals(
            1, [SELECT COUNT() FROM Lease_Activity__c WHERE Lease_Inquiry__c = :inq.Id],
            'The failed insert never commits — only the seeded opening entry remains'
        );
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :inq.Id], 'No Task was ever attempted');
        Lease_Inquiry__c after = theInquiry();
        System.assertEquals('Landlord', after.Ball_In_Court__c, 'Parent was never reached — the first DML failed before it');
    }

    // Proves Database.rollback(sp) UNDOES COMMITTED WORK in the DmlException branch.
    //
    // Why not an over-length reminderName (the obvious lever)? The new length guard in
    // addUpdate() is an up-front input check, so it throws before the SOQL and before any
    // DML — an over-length name can no longer reach the Task insert at all. A test built on
    // it would short-circuit at the guard and prove nothing about rollback. See the note in
    // the controller header.
    //
    // The remaining un-guarded input that reaches the third DML is reminderDate.
    // 9999-01-01 is outside Salesforce's valid Date range (verified against the org:
    // 1700-01-01..4000-12-31 insert, anything outside throws FIELD_INTEGRITY_EXCEPTION), so
    // the Task insert fails AFTER the Lease_Activity__c insert and the Lease_Inquiry__c
    // update have both already succeeded in this transaction. That is the committed work
    // the rollback must revert.
    @isTest static void addUpdateReminderDateOutOfRangeRollsBackCommittedWork() {
        Lease_Inquiry__c before = theInquiry();
        String ballBefore = before.Ball_In_Court__c;
        System.assertEquals('Landlord', ballBefore, 'Precondition: setup leaves the ball with the Landlord');

        // Deliberately DIFFERENT from ballBefore. If this matched, 'unchanged afterwards'
        // would be vacuous — the update would never have been a change in the first place.
        String ballAttempted = 'Tenant';
        System.assertNotEquals(ballBefore, ballAttempted, 'The attempted ball must differ, or the assertion below proves nothing');

        Boolean threw = false;
        Test.startTest();
        try {
            LeaseInquiryController.addUpdate(
                before.Id, 'Redline sent; chasing signature.', ballAttempted, false,
                true, 'Chase the signed LOI', Date.newInstance(9999, 1, 1)
            );
            System.assert(false, 'Expected an out-of-range reminder date to fail the Task insert');
        } catch (AuraHandledException e) {
            threw = true;
            // Proves this landed in the DmlException branch (the generic wrap) rather than
            // the AuraHandledException branch — i.e. a real platform DML failure, not an
            // input check.
            System.assertEquals(
                'This update could not be saved. Check your entry and try again, or contact your administrator.',
                e.getMessage(),
                'A failed Task insert surfaces the fixed generic message via the DmlException branch'
            );
            String m = e.getMessage();
            System.assert(!m.contains('ActivityDate'), 'No field API name leaks to the user: ' + m);
            System.assert(!m.containsIgnoreCase('FIELD_INTEGRITY'), 'No platform status code leaks to the user: ' + m);
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'An out-of-range reminder date is rejected by the platform');

        // ── The rollback assertions: all three below were COMMITTED-then-REVERTED. ──
        System.assertEquals(
            1, [SELECT COUNT() FROM Lease_Activity__c WHERE Lease_Inquiry__c = :before.Id],
            'The appended log entry committed before the Task insert failed, and was rolled back — only the seeded opening entry remains'
        );
        Lease_Inquiry__c after = theInquiry();
        System.assertEquals(
            ballBefore, after.Ball_In_Court__c,
            'The parent update committed as Tenant before the Task insert failed, and was rolled back to Landlord'
        );
        System.assertEquals(
            0, [SELECT COUNT() FROM Task WHERE WhatId = :before.Id],
            'The Task itself never committed'
        );
    }

    // The up-front length guard: an over-length reminder name is rejected with a message
    // that names the actual problem, instead of the generic DML_FAILURE_MESSAGE the
    // platform's STRING_TOO_LONG would have produced.
    @isTest static void addUpdateReminderNameTooLongIsRejectedWithSpecificMessage() {
        Lease_Inquiry__c inq = theInquiry();
        Boolean threw = false;
        Test.startTest();
        try {
            LeaseInquiryController.addUpdate(
                inq.Id, 'Reminder name overflows Subject.', 'Tenant', false,
                true, 'A'.repeat(256), Date.today().addDays(7)
            );
            System.assert(false, 'Expected a 256-char reminder name to be rejected');
        } catch (AuraHandledException e) {
            threw = true;
            System.assertEquals(
                'The reminder name is too long. Shorten it to 255 characters or fewer.',
                e.getMessage(),
                'The guard names the real problem rather than the generic save failure'
            );
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'A 256-char reminder name is rejected');
        // The guard fires before any DML, so there is nothing to roll back.
        System.assertEquals(1, [SELECT COUNT() FROM Lease_Activity__c WHERE Lease_Inquiry__c = :inq.Id],
            'The guard short-circuits before the log entry is inserted');
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :inq.Id], 'No Task is attempted');
        System.assertEquals('Landlord', theInquiry().Ball_In_Court__c, 'The parent is never touched');
    }

    // The guard measures the TRIMMED name, matching what the Task insert stores. A name that
    // is over 255 raw but fits once trimmed must be accepted, not rejected.
    @isTest static void addUpdateReminderNameOverLengthOnlyBeforeTrimIsAccepted() {
        Lease_Inquiry__c inq = theInquiry();
        String padded = 'A'.repeat(250) + '          '; // 260 raw, 250 trimmed
        System.assertEquals(260, padded.length(), 'Raw length exceeds the 255 limit');
        Test.startTest();
        LeaseInquiryController.addUpdate(
            inq.Id, 'Padded reminder name.', 'Tenant', false, true, padded, Date.today().addDays(3)
        );
        Test.stopTest();
        List<Task> tasks = [SELECT Subject FROM Task WHERE WhatId = :inq.Id];
        System.assertEquals(1, tasks.size(), 'A name that fits once trimmed is accepted by the guard');
        System.assertEquals(250, tasks[0].Subject.length(), 'The stored Subject is the trimmed name');
    }

    @isTest static void addUpdateBlankDetailsThrows() {
        Lease_Inquiry__c inq = theInquiry();
        Boolean threw = false;
        try {
            LeaseInquiryController.addUpdate(inq.Id, '   ', 'Tenant', false, false, null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank details is rejected');
    }

    @isTest static void addUpdateNullInquiryThrows() {
        Boolean threw = false;
        try {
            LeaseInquiryController.addUpdate(null, 'anything', 'Tenant', false, false, null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }

    @isTest static void closedInquiryDoesNotAdvance() {
        Lease_Inquiry__c inq = theInquiry();
        inq.Stage__c = 'Lease Signed';
        inq.Status__c = 'Closed Won';
        update inq;
        Test.startTest();
        LeaseInquiryController.addUpdate(inq.Id, 'Post-close note.', 'Tenant', true, false, null, null);
        Test.stopTest();
        Lease_Inquiry__c after = theInquiry();
        System.assertEquals('Lease Signed', after.Stage__c, 'Closed inquiry never advances');
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(inq.Id);
        System.assertEquals(true, v.closed);
        System.assertEquals(false, v.canAdvance);
        System.assertEquals(null, v.nextStage);
    }

    @isTest static void getLogNullReturnsEmpty() {
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(null);
        System.assertEquals(0, v.entries.size());
    }

    @isTest static void homeKpis() {
        LeaseInquiryController.HomeKpis k = LeaseInquiryController.getHomeKpis();
        System.assertEquals(1, k.active, 'one active inquiry in setup');
        System.assertEquals(1, k.waitingLandlord, 'ball defaults to Landlord');
        System.assertEquals(0, k.stalled, 'stage started today, not stalled');
        System.assertEquals(0, k.signed);
    }

    @isTest static void recentInquiries() {
        List<LeaseInquiryController.InquiryRow> rows = LeaseInquiryController.getRecentInquiries();
        System.assertEquals(1, rows.size());
        System.assertEquals('Sunrise Cafe', rows[0].tenant);
        System.assertEquals('Inquiry Received', rows[0].stage);
        System.assertEquals(false, rows[0].closed);
    }

    @isTest static void pipelineByStage() {
        List<LeaseInquiryController.StageCount> out = LeaseInquiryController.getPipelineByStage();
        System.assertEquals(7, out.size(), 'one bucket per stage (incl. Lease Ready)');
        System.assertEquals('Inquiry Received', out[0].stage);
        System.assertEquals(1, out[0].count, 'the one active inquiry sits in Inquiry Received');
    }

    @isTest static void attention() {
        // The setup inquiry has the ball with the Landlord → surfaces in attention.
        List<LeaseInquiryController.InquiryRow> rows = LeaseInquiryController.getAttention();
        System.assertEquals(1, rows.size());
        System.assertEquals('Sunrise Cafe', rows[0].tenant);
    }

    @isTest static void signedYtdCounts() {
        Lease_Inquiry__c inq = theInquiry();
        inq.Stage__c = 'Lease Signed';
        inq.Status__c = 'Closed Won';
        update inq; // Signed Date flow stamps today (this year)
        Lease_Inquiry__c after = [SELECT Signed_Date__c FROM Lease_Inquiry__c WHERE Id = :inq.Id];
        System.assertEquals(Date.today(), after.Signed_Date__c, 'Signed Date flow stamps on Closed Won');
        LeaseInquiryController.HomeKpis k = LeaseInquiryController.getHomeKpis();
        System.assertEquals(1, k.signed, 'Closed Won with a Signed Date this year counts toward YTD');
        System.assertEquals(0, k.active, 'no active inquiries remain');
    }

    @isTest static void leaseCreatedAtDraftingAndSummary() {
        Lease_Inquiry__c inq = theInquiry();
        LeaseInquiryController.LeaseSummary before = LeaseInquiryController.getLeaseSummary(inq.Id);
        System.assertEquals(false, before.exists, 'no Lease before drafting');
        Test.startTest();
        inq.Stage__c = 'Lease Drafting';
        update inq; // Create Lease flow fires
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Lease__c WHERE Lease_Inquiry__c = :inq.Id], 'one Lease auto-created');
        LeaseInquiryController.LeaseSummary after = LeaseInquiryController.getLeaseSummary(inq.Id);
        System.assertEquals(true, after.exists, 'Lease auto-created at Lease Drafting');
        System.assertEquals('Draft', after.stage);
        System.assertEquals(3, after.steps.size());
        System.assertEquals(true, after.steps[0].current, 'Draft is the current step');
    }
}
