/**
 * @description Tests BovBrokerChangeController — the thin read behind `c/bovBrokerChangeHistory`
 * (2026-08-20, Tranche 2 Workstream B / design D4.6).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE RETURN TYPE CHANGED ON 2026-08-25 — `List<ChangeRow>` BECAME `HistoryView`
 * ─────────────────────────────────────────────────────────────────────────────────────
 * The card is titled "Broker Selection" and used to list REPLACEMENTS only, so a sale whose broker
 * had been selected and never replaced rendered "(0) — No broker changes recorded". The payload now
 * carries both halves — `selected` (up to two rows, one per selection slot) and `changes` (the old
 * payload, unchanged) — and every test below reads `view.changes` where it used to read the list.
 * `getHistory_returnsBothSelectionSlots_preferredFirst` is the new half's test.
 *
 * ⚠ THE NULL-ANCHOR AND EMPTY TESTS NOW ASSERT ON *BOTH* LISTS, and that is not padding: the method
 * makes TWO selector calls now, so it has two chances to throw on page load and two lists that must
 * arrive instantiated rather than null. A test that checked only `changes` would let a null
 * `selected` reach a `for:each` in the browser.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE MOST IMPORTANT TEST HERE IS `getHistory_noChanges_returnsAnEmptyListAndDoesNotThrow`
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Most dispositions never replace a broker, so EMPTY is the majority state of this card — commoner
 * than any populated one. If empty ever became a throw (or the client ever rendered it as one),
 * the visible result would be a permanent error banner on most disposition record pages. Everything
 * else in this class is a detail by comparison.
 *
 * ⚠ THE DTO MEMBER-NAME TEST IS THE SILENT HALF. A renamed `@AuraEnabled` member does not fail a
 * deploy, does not fail an Apex test that reads it through Apex, and does not throw in the browser —
 * the card just renders blanks. `getHistory_mapsEveryDtoMember` asserts every member is populated
 * from a known fixture value, so a mapping dropped in a refactor fails HERE rather than silently in
 * production. The NAMES themselves are pinned on the client side, in the Jest suite.
 *
 * NO 251-RECORD BULK TEST, AND THE REASON IS THE SELECTOR'S CAP. `getHistory` is a straight map
 * over whatever `BovBrokerChangeSelector.selectByDispositionId` returns, and that method caps at
 * 200 rows — the volume behaviour therefore belongs to the selector and is tested there
 * (`BovBrokerChangeSelectorTest.selectByDispositionId_bulk251_isCappedAtTheDocumentedLimit`, which
 * does insert 251). Duplicating the fixture here would re-test the selector through a wrapper.
 *
 * @see force-app/main/default/classes/BovBrokerChangeController.cls
 */
@isTest
private class BovBrokerChangeControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(asset.Id, true);
    }

    private static Id dispositionId() {
        return [SELECT Id FROM Disposition__c LIMIT 1].Id;
    }

    @isTest
    static void getHistory_mapsEveryDtoMember() {
        Id dispId = dispositionId();
        BOV_Broker_Change__c seeded = TestDataFactory.createBovBrokerChange(dispId, true);
        String changeNumber =
            [SELECT Name FROM BOV_Broker_Change__c WHERE Id = :seeded.Id].Name;

        Test.startTest();
        BovBrokerChangeController.HistoryView view =
            BovBrokerChangeController.getHistory(dispId);
        Test.stopTest();

        Assert.areEqual(1, view.changes.size(), 'One seeded change, one row');
        BovBrokerChangeController.ChangeRow row = view.changes[0];
        Assert.areEqual(String.valueOf(seeded.Id), row.id, 'id');
        Assert.areEqual(changeNumber, row.changeNumber, 'changeNumber (the BBC- AutoNumber)');
        Assert.areEqual('Outgoing Brokerage 0', row.outgoingBrokerFirm, 'outgoingBrokerFirm');
        Assert.areEqual('Incoming Brokerage 0', row.incomingBrokerFirm, 'incomingBrokerFirm');
        Assert.areEqual('Performance Issue', row.reason, 'reason');
        Assert.areEqual('Test broker change 0', row.notes, 'notes');
        Assert.isNotNull(row.entryDateTime, 'entryDateTime');
        Assert.areEqual(UserInfo.getName(), row.loggedBy,
            'loggedBy must be the User NAME, flattened off Logged_By__r — not the Id');
    }

    /**
     * 🔴 EMPTY IS SUCCESS. See the class header: this is the majority state of the card, and the
     * one failure mode that would be visible on most disposition record pages in the org.
     */
    @isTest
    static void getHistory_noChanges_returnsAnEmptyListAndDoesNotThrow() {
        Id dispId = dispositionId();

        Test.startTest();
        BovBrokerChangeController.HistoryView view =
            BovBrokerChangeController.getHistory(dispId);
        Test.stopTest();

        Assert.isNotNull(view.changes, 'Never null — the client iterates this directly');
        Assert.isNotNull(view.selected, 'Never null — the client iterates this directly');
        Assert.areEqual(0, view.selected.size(),
            'No broker has been Selected on this fixture either. BOTH halves empty is what makes '
            + 'the card render its empty state — one empty half must NOT.');
        Assert.areEqual(0, view.changes.size(),
            'A disposition that never replaced a broker returns an empty list, NOT an exception. '
            + 'The client renders "No broker selected yet" from exactly this — but ONLY because '
            + 'the selection half above is empty too. Either half populated means an entry.');
    }

    @isTest
    static void getHistory_nullDispositionId_returnsEmptyRatherThanThrowing() {
        Test.startTest();
        BovBrokerChangeController.HistoryView view =
            BovBrokerChangeController.getHistory(null);
        Test.stopTest();

        Assert.areEqual(0, view.selected.size(),
            'The selection half must degrade to empty on a null anchor too — it is a second '
            + 'selector call, and a second chance to throw on page load.');
        Assert.areEqual(0, view.changes.size(),
            'A card rendered before its recordId arrives must degrade to empty, not to an error '
            + 'toast on page load');
    }

    /** The controller must not re-sort or reverse what the selector already ordered. */
    @isTest
    static void getHistory_preservesTheSelectorsNewestFirstOrder() {
        Id dispId = dispositionId();
        List<BOV_Broker_Change__c> seeded =
            TestDataFactory.createBovBrokerChanges(3, dispId, false);
        // Inserted oldest-first so insert order is the OPPOSITE of the expected read order.
        insert new List<BOV_Broker_Change__c>{ seeded[2], seeded[1], seeded[0] };

        Test.startTest();
        BovBrokerChangeController.HistoryView view =
            BovBrokerChangeController.getHistory(dispId);
        Test.stopTest();

        Assert.areEqual(3, view.changes.size(), 'All three rows');
        Assert.areEqual('Incoming Brokerage 0', view.changes[0].incomingBrokerFirm,
            'The newest change must still be first after the DTO mapping');
        Assert.areEqual('Incoming Brokerage 2', view.changes[2].incomingBrokerFirm,
            'And the oldest last');
    }

    /**
     * 🔴 THE CONTRACT UNDER TEST IS "NO RAW EXCEPTION EVER REACHES THE CLIENT" — not any particular
     * exception.
     *
     * ⚠ THIS TEST DELIBERATELY ACCEPTS TWO OUTCOMES, WHICH NEEDS DEFENDING. A wrong-SObjectType Id
     * bound into `WHERE Disposition__c = :id` is the only failure this class can provoke without a
     * mocking seam, and the platform is entitled to answer it either by throwing (a QueryException,
     * which the catch must convert) or by simply matching nothing (an empty list, which is a
     * perfectly good answer). Asserting ONE of those would pin an implementation detail of the
     * platform rather than the behaviour of this class. What is asserted instead is the thing that
     * actually matters and holds in both branches: an `AuraHandledException` carrying the FIXED
     * GENERIC message, never a raw exception and never platform text naming a column — because the
     * real trigger for this path in production is an FLS denial on a 2026-08-20 field, whose
     * QueryException reads `No such column`, which would be shown to a user as a schema error.
     */
    @isTest
    static void getHistory_wrongTypeId_neverLeaksARawException() {
        Id notADisposition = UserInfo.getUserId();

        Test.startTest();
        Boolean threwSomethingElse = false;
        try {
            BovBrokerChangeController.HistoryView view =
                BovBrokerChangeController.getHistory(notADisposition);
            Assert.areEqual(0, view.changes.size(),
                'If the platform matched instead of throwing, it must have matched nothing');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('could not be loaded'),
                'The FIXED GENERIC message must be surfaced, not platform detail: ' + e.getMessage());
            Assert.isFalse(e.getMessage().contains('No such column'),
                'An FLS denial must never reach the user as a schema error');
        } catch (Exception e) {
            threwSomethingElse = true;
        }
        Test.stopTest();

        Assert.isFalse(threwSomethingElse,
            'Anything other than AuraHandledException escaping this method reaches the LWC as an '
            + 'unhandled error — ARCHITECTURE.md §5 requires the boundary to convert it');
    }

    /**
     * 🔴 THE NEW HALF, AND THE ONE SHAPE THAT PRODUCED THE DEFECT: a disposition whose broker IS
     * selected. Both SLOTS are occupied here — a preferred broker and a score-selected one — which
     * is a NORMAL state on this object, not an anomaly: `BovSubmissionSelectionGuardService` permits
     * exactly one Selected row per slot, and `DispositionApprovalService` relies on being able to
     * tell the two apart.
     *
     * WHAT IT PINS, AND WHY EACH ONE CAN FAIL INDEPENDENTLY:
     *   1. BOTH rows come back. A `LIMIT 1` in the selector — the shape three of its neighbours
     *      used to have — would silently drop the second broker off the card.
     *   2. PREFERRED IS FIRST. The order is the selector's `ORDER BY`, deliberately identical to
     *      the clause Submit for Approval uses, and the client does not re-sort. Asserting only
     *      `size() == 2` would pass with the rows in either order.
     *   3. THE BASIS PHRASE IS RESOLVED PER ROW. `basisOf`'s three flags are the only thing that
     *      distinguishes two otherwise identical Selected rows, and the phrase is what the card
     *      prints; a mapping that read one flag for both rows would still return two rows.
     *   4. NAME AND FIRM ARE MAPPED FROM THE PERSISTED VALUES, not from the literals this test
     *      typed. ⚠ THAT DISTINCTION IS LOAD-BEARING HERE: `BovSubmissionBrokerStampService`
     *      OVERWRITES `Contact_Name__c` and `Broker_Firm__c` from the `Broker__c` Contact on every
     *      save, so a fixture literal never survives the insert. The firms below are pinned by
     *      pointing `Broker__c` at a Contact that already carries them
     *      (`createBrokerContactWithFirm`), which is the only mechanism that works; the NAME is
     *      read back out of the database rather than asserted as a literal, because both fixture
     *      Contacts are built with the same generated LastName.
     *
     * ⚠ NO 251-ROW BULK TEST, AND IT IS NOT AN OVERSIGHT. `.claude/rules/bulk-test-rule.md`'s
     * mandate exists to force a SECOND trigger-batch firing; this is a read against a WHERE clause
     * that a live guard trigger caps at TWO rows per disposition. 251 Selected rows on one
     * disposition is not a volume production can reach — it is a state the guard refuses — so the
     * test would prove nothing and could not even be constructed without disabling the guard.
     */
    @isTest
    static void getHistory_returnsBothSelectionSlots_preferredFirst() {
        Id dispId = dispositionId();
        List<BOV_Submission__c> submissions =
            TestDataFactory.createBovSubmissions(2, dispId, false);

        // The PREFERRED slot. `Is_Preferred_Broker__c` is what puts it first.
        submissions[0].Broker__c =
            TestDataFactory.createBrokerContactWithFirm('Preferred Brokerage', true).Id;
        submissions[0].Submission_Status__c = 'Selected';
        submissions[0].Is_Preferred_Broker__c = true;

        // The SCORED slot — non-preferred and Selected, which is the second slot the guard counts.
        submissions[1].Broker__c =
            TestDataFactory.createBrokerContactWithFirm('Scored Brokerage', true).Id;
        submissions[1].Submission_Status__c = 'Selected';
        submissions[1].Is_System_Selected__c = true;
        insert submissions;

        // The stamp service rewrote both display columns on insert (see the header), so the
        // expected NAME is whatever landed in the database, not what this test typed.
        Map<Id, BOV_Submission__c> persisted = new Map<Id, BOV_Submission__c>(
            [SELECT Id, Contact_Name__c, Broker_Firm__c
             FROM BOV_Submission__c
             WHERE Id IN :submissions]
        );

        Test.startTest();
        BovBrokerChangeController.HistoryView view =
            BovBrokerChangeController.getHistory(dispId);
        Test.stopTest();

        Assert.areEqual(2, view.selected.size(),
            'BOTH selection slots must come back. A disposition legitimately carries one preferred '
            + 'and one score-selected broker at the same time, and a card that shows one of them '
            + 'is a card that hides an appointed broker.');

        BovBrokerChangeController.SelectedRow preferred = view.selected[0];
        BovBrokerChangeController.SelectedRow scored = view.selected[1];

        Assert.areEqual('Preferred Brokerage', preferred.brokerFirm,
            'PREFERRED FIRST — the selector orders on Is_Preferred_Broker__c DESC and the client '
            + 'does not re-sort. If these two ever swap, the card disagrees with Submit for '
            + 'Approval about which broker is "first".');
        Assert.areEqual('Scored Brokerage', scored.brokerFirm, 'then the scored slot');

        Assert.areEqual('Preferred broker', preferred.basis,
            'The basis phrase is resolved PER ROW from the three flags — it is the only thing '
            + 'distinguishing two otherwise identical Selected rows on the card');
        Assert.areEqual('System selected by score', scored.basis, 'and the scored row says so');

        Assert.areEqual(persisted.get(submissions[0].Id).Contact_Name__c, preferred.brokerName,
            'brokerName is the PERSISTED Contact_Name__c — the broker stamp overwrites any '
            + 'hand-typed literal on insert, so asserting the fixture string would fail for the '
            + 'wrong reason');
        Assert.areEqual(String.valueOf(submissions[0].Id), preferred.id, 'id (the client key)');
        Assert.isNotNull(preferred.selectedDateTime,
            'selectedDateTime is LastModifiedDate and is never null on a persisted row — the '
            + 'card renders it unlabelled beside a calendar icon, so a null would render blank');

        Assert.areEqual(0, view.changes.size(),
            '🔴 AND NO REPLACEMENTS — this is the EXACT shape that produced the reported defect. '
            + 'Before 2026-08-25 this payload was empty and the card, titled "Broker Selection", '
            + 'rendered "(0) — No broker changes recorded" on a sale with two appointed brokers.');
    }
}
