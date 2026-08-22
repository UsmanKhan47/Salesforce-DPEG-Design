// The ONLY `Utility_Bill__c` trigger in this org (ARCHITECTURE.md section 2 /
// .claude/rules/apex-layering-rule.md - one trigger per object). Every future utility-bill
// automation belongs in UtilityBillTriggerHandler, never in a second trigger file.
//
// One line by contract. Two jobs, in two context families:
//
//   before insert / before update  -> write Consumption__c on the same save
//                                     (rollover-aware, and refusing to guess on a meter
//                                     swap). UtilityBillService.applyConsumption.
//   after insert / update / delete / undelete
//                                  -> rebuild Prior_Utility_Bill__c for every affected
//                                     meter. UtilityBillService.relinkChains.
//
// WHY ALL FOUR AFTER CONTEXTS ARE PRESENT, INCLUDING THE TWO THAT LOOK REDUNDANT:
// `Prior_Utility_Bill__c` is the single input every variance formula on this object reads,
// and it is invalidated by four separate events - three of them silently.
//   after insert    a BACK-DATED bill (Jan and Mar exist, Feb is entered later) leaves Mar
//                   pointing at Jan. No error, just wrong variance on two records.
//   after update    a corrected Read_Date__c reorders the sequence around it.
//   after delete    the lookup is deleteConstraint = SetNull, so deleting a MIDDLE bill
//                   BLANKS its successor's pointer and that successor's variance simply
//                   disappears from the record page.
//   after undelete  no `before undelete` context exists on the platform, so a restored bill
//                   can only be put back into its sequence here.
//
// No `before delete`: nothing needs to be read or vetoed before the row goes, and the
// successor repair needs the row to be GONE before the chain is recomputed.
trigger UtilityBillTrigger on Utility_Bill__c (
        before insert, before update,
        after insert, after update, after delete, after undelete) {
    new UtilityBillTriggerHandler().run();
}
