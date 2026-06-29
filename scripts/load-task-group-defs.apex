// Load/refresh the 11 Task_Group_Def__mdt records (PDF source of truth) via the Apex
// Metadata API (file-based .md-meta.xml deploy throws UNKNOWN_EXCEPTION in this org).
// Dev names reuse the original A-J records (upsert) + add H2; Letter__c drives the join.
List<Map<String, Object>> recs = new List<Map<String, Object>>{
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.A_Contract_Execution', 'label' => 'A. Contract Execution & Title Opening',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'A', 'Group_Name__c' => 'Contract Execution & Title Opening', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 1 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.B_Earnest_Money_Deposit', 'label' => 'B. Earnest Money Wire',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'B', 'Group_Name__c' => 'Earnest Money Wire', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 2 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.C_Title_Survey', 'label' => 'C. Property Condition Report (BBG)',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'C', 'Group_Name__c' => 'Property Condition Report (BBG)', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 3 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.D_Due_Diligence', 'label' => 'D. LPRD Cash Flow Verification',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'D', 'Group_Name__c' => 'LPRD Cash Flow Verification', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 4 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.E_Environmental_Ph1', 'label' => 'E. Appraisal',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'E', 'Group_Name__c' => 'Appraisal', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 5 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.F_Financing', 'label' => 'F. Loan Package & Financing',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'F', 'Group_Name__c' => 'Loan Package & Financing', 'Owner_Label__c' => 'Danish', 'Conditional__c' => true, 'Condition_Field__c' => 'Loan_Required__c', 'Sequence__c' => 6 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.G_Insurance', 'label' => 'G. Insurance',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'G', 'Group_Name__c' => 'Insurance', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 7 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.H_Entity_IR_Setup', 'label' => 'H. Entity Formation & Investor Relations',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'H', 'Group_Name__c' => 'Entity Formation & Investor Relations', 'Owner_Label__c' => 'FES', 'Conditional__c' => false, 'Sequence__c' => 8 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.H2_Tenant_Interviews', 'label' => 'H2. Tenant Interviews & Estoppels',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'H2', 'Group_Name__c' => 'Tenant Interviews & Estoppels', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 9 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.I_Tenants_Closing_Wire', 'label' => 'I. Pre-Closing & Closing',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'I', 'Group_Name__c' => 'Pre-Closing & Closing', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 10 } },
    new Map<String, Object>{ 'fullName' => 'Task_Group_Def.J_Post_Close_Handoff', 'label' => 'J. Post-Closing Checklist',
        'fields' => new Map<String, Object>{ 'Letter__c' => 'J', 'Group_Name__c' => 'Post-Closing Checklist', 'Owner_Label__c' => 'Danish', 'Conditional__c' => false, 'Sequence__c' => 11 } }
};

Metadata.DeployContainer container = new Metadata.DeployContainer();
for (Map<String, Object> r : recs) {
    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
    cm.fullName = (String) r.get('fullName');
    cm.label = (String) r.get('label');
    Map<String, Object> fields = (Map<String, Object>) r.get('fields');
    for (String f : fields.keySet()) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = f;
        v.value = fields.get(f);
        cm.values.add(v);
    }
    container.addMetadata(cm);
}
System.debug('Enqueued group-def deploy: ' + Metadata.Operations.enqueueDeployment(container, null));
