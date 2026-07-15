// End-to-end verification of the Junior-feedback build (P1-P5): drives one deal
// through the full lifecycle - intake -> approval -> conversion -> NDA gate ->
// underwriting approval -> LOI prep + panel approval -> counters/ball-in-court ->
// LOI signed -> PSA versions -> execution -> transaction -> closed - and asserts
// every gate. Notifications fire live to the role groups (check the bell).
String stampId = String.valueOf(Crypto.getRandomInteger()).right(6);

// 1. Intake (manual entry) - stamps First Seen + DPEG First via Lead_Intake_Stamp.
Lead l = new Lead(LastName = 'Lifecycle', Company = 'E2E Verify ' + stampId,
    Property_Address__c = stampId + ' Verification Blvd', Status = 'New',
    LeadSource = 'Manual Entry', Deal_Type__c = 'Commercial', Asset_Type__c = 'Retail',
    Guidance_Price__c = 21000000, Guidance_Cap_Rate__c = 6.5);
insert l;
l = [SELECT First_Seen_Date__c, DPEG_First__c FROM Lead WHERE Id = :l.Id];
System.assert(l.First_Seen_Date__c != null, 'P1 First Seen stamped');
System.assert(l.DPEG_First__c == UserInfo.getUserId(), 'P1 DPEG First stamped');
System.debug('CHECK 1 intake stamps: OK');

// 2. Approve for underwriting (checkbox -> approver stamp + team notification).
l.Approved_for_UW__c = true;
update l;
l = [SELECT Approved_By__c, Approval_Date__c FROM Lead WHERE Id = :l.Id];
System.assert(l.Approved_By__c == UserInfo.getUserId() && l.Approval_Date__c != null, 'P1 approval stamps');
System.debug('CHECK 2 lead approval: OK');

// 3. Convert -> Opportunity + Property.
Database.LeadConvert lc = new Database.LeadConvert();
lc.setLeadId(l.Id);
lc.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel);
Database.LeadConvertResult res = Database.convertLead(lc);
System.assert(res.isSuccess(), 'P1 conversion allowed for approved lead');
Id oppId = res.getOpportunityId();
Opportunity o = [SELECT Property__c, RecordType.DeveloperName FROM Opportunity WHERE Id = :oppId];
System.assert(o.Property__c != null && o.RecordType.DeveloperName == 'Commercial', 'Property + record type');
System.debug('CHECK 3 conversion: OK');

// 4. NDA gate: blocked without signed NDA, then Initiate Underwriting checkbox (12B.I).
Boolean blocked = false;
try { update new Opportunity(Id = oppId, StageName = 'Underwriting'); } catch (DmlException e) { blocked = true; }
System.assert(blocked, 'P3 NDA gate blocks Underwriting');
NDA__c nda = new NDA__c(Opportunity__c = oppId, Status__c = 'Signed', NDA_Signed__c = true);
insert nda;
update new Opportunity(Id = oppId, Primary_NDA__c = nda.Id, Initiate_Underwriting__c = true);
System.assertEquals('Underwriting', [SELECT StageName FROM Opportunity WHERE Id = :oppId].StageName);
System.debug('CHECK 4 NDA gate + initiate checkbox: OK');

// 5. Principal underwriting approval (12B complete -> submit -> approve).
update new Opportunity(Id = oppId, Underwriting_Complete__c = true, Underwritten_NOI__c = 1400000);
Approval.ProcessSubmitRequest uw = new Approval.ProcessSubmitRequest();
uw.setObjectId(oppId);
Approval.process(uw);
for (ProcessInstanceWorkitem wi : [SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :oppId]) {
    Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
    wr.setWorkitemId(wi.Id); wr.setAction('Approve'); wr.setComments('Principal go.');
    Approval.process(wr);
    break; // FirstResponse: one principal is enough
}
o = [SELECT StageName, UW_Approved__c, UW_Approved_By__c FROM Opportunity WHERE Id = :oppId];
System.assertEquals('Initiate LOI', o.StageName, 'UW approval advances');
System.assert(o.UW_Approved__c && o.UW_Approved_By__c != null, 'UW audit stamped');
System.debug('CHECK 5 underwriting approval: OK');

// 6. LOI prep gate + unanimous panel approval.
LOI__c loi = new LOI__c(Opportunity__c = oppId, Offer_Price__c = 19500000, LOI_Status__c = 'Pending Approval');
insert loi;
update new Opportunity(Id = oppId, Primary_LOI__c = loi.Id, LOI_Prep_Approved__c = true, StageName = 'LOI Under Approval');
Approval.ProcessSubmitRequest ls = new Approval.ProcessSubmitRequest();
ls.setObjectId(oppId);
Approval.process(ls);
for (ProcessInstanceWorkitem wi : [SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :oppId AND ProcessInstance.Status = 'Pending']) {
    Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
    wr.setWorkitemId(wi.Id); wr.setAction('Approve'); wr.setComments('Unanimous.');
    Approval.process(wr); // both principals (admin acts on each)
}
o = [SELECT StageName FROM Opportunity WHERE Id = :oppId];
loi = [SELECT LOI_Status__c, Approved_By__c, Approval_Comments__c FROM LOI__c WHERE Id = :loi.Id];
System.assertEquals('LOI Submitted', o.StageName, 'LOI approval advances');
System.assert(loi.LOI_Status__c == 'Approved' && loi.Approved_By__c != null, 'LOI audit stamped');
System.debug('CHECK 6 LOI prep + panel approval: OK');

// 7. Counters flip the ball (seller -> Us, ours -> Seller) + notify each time.
CounterOfferController.saveCounterOffer(loi.Id, 'Seller', 20500000, 6.1, Date.today(), 'Seller pushes back');
System.assertEquals('Us', [SELECT Ball_In_Court__c FROM LOI__c WHERE Id = :loi.Id].Ball_In_Court__c);
CounterOfferController.saveCounterOffer(loi.Id, 'Ours', 20000000, 6.25, Date.today(), 'Split the difference');
System.assertEquals('Seller', [SELECT Ball_In_Court__c FROM LOI__c WHERE Id = :loi.Id].Ball_In_Court__c);
System.debug('CHECK 7 counters + ball-in-court: OK');

// 8. LOI signed -> Legal + IR notified; deal to LOI Signed then PSA Negotiation.
update new LOI__c(Id = loi.Id, LOI_Signed__c = true, LOI_Signed_Date__c = Date.today(), Final_Agreed_Price__c = 20000000);
update new Opportunity(Id = oppId, StageName = 'LOI Signed');
update new Opportunity(Id = oppId, StageName = 'PSA Negotiation');
Contract_Review__c cr = [SELECT Id, Stage__c FROM Contract_Review__c WHERE Opportunity__c = :oppId];
System.debug('CHECK 8 LOI signed + Contract Review auto-created: OK');

// 9. PSA versions: seller initial draft -> our redline (ball flips, status derives).
PsaVersionController.saveVersion(cr.Id, 'Seller', Date.today(), 'Seller first draft', 'https://example.com/psa-v1');
cr = [SELECT Negotiation_Status__c, Ball_In_Court__c FROM Contract_Review__c WHERE Id = :cr.Id];
System.assert(cr.Negotiation_Status__c == 'Initial Draft' && cr.Ball_In_Court__c == 'Us', 'Initial draft state');
PsaVersionController.saveVersion(cr.Id, 'Ours', Date.today(), 'Our redline', null);
cr = [SELECT Id, Negotiation_Status__c, Ball_In_Court__c FROM Contract_Review__c WHERE Id = :cr.Id];
System.assert(cr.Negotiation_Status__c == 'Buyer Counter' && cr.Ball_In_Court__c == 'Seller', 'Redline state');
System.debug('CHECK 9 PSA versions: OK');

// 10. Ready -> Executed: Opp stamped, Transaction auto-created, fan-out armed.
update new Contract_Review__c(Id = cr.Id, Negotiation_Status__c = 'Ready for Execution');
update new Contract_Review__c(Id = cr.Id, Negotiation_Status__c = 'Executed', Contract_Value__c = 20000000);
o = [SELECT StageName, Contract_Signed__c, Deal_Status__c, Deal_Bucket__c FROM Opportunity WHERE Id = :oppId];
System.assertEquals('PSA Executed', o.StageName, 'Execution advances the deal');
System.assertEquals('PSA Executed/About to Close', o.Deal_Bucket__c, 'Bucket follows');
Transaction__c txn = [SELECT Id, Status__c, Tasks_Total__c FROM Transaction__c WHERE Opportunity__c = :oppId];
System.assertEquals('Active', txn.Status__c, 'Transaction opened');
System.debug('CHECK 10 execution handoff: OK (tasks fanned out: ' + txn.Tasks_Total__c + ')');

// 11. Transaction closed -> deal Bought/Closed + congratulations notification.
update new Transaction__c(Id = txn.Id, Status__c = 'Closed');
o = [SELECT StageName, Deal_Category__c, Deal_Status__c, Deal_Bucket__c FROM Opportunity WHERE Id = :oppId];
System.assertEquals('Closed Won', o.StageName, 'Deal closes');
System.assertEquals('Bought/Closed', o.Deal_Bucket__c, 'Final bucket');
System.assertEquals('Asset Under Management', o.Deal_Status__c, 'AUM stamped');
System.debug('CHECK 11 close + congratulate: OK');

System.debug('=== E2E LIFECYCLE VERIFIED: all 11 checkpoints passed ===');
