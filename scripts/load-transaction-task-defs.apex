// Load the 82 Transaction_Task_Def__mdt records (DPEG_Transaction.pdf checklist) via the
// Apex Metadata API. Each row = { groupLetter, seqInGroup, ownerLabel, dueDayOffset, subject }.
// Owner = role label (display only); actual Task.OwnerId = the Transaction owner at fan-out.
List<List<Object>> defs = new List<List<Object>>{
    // A — Contract Execution & Title Opening
    new List<Object>{ 'A', 1, 'Danish', 0, 'Receive executed contract from legal counsel' },
    new List<Object>{ 'A', 2, 'Danish', 1, 'Send executed contract to title company' },
    new List<Object>{ 'A', 3, 'Danish', 1, 'Receive title file number from title company' },
    new List<Object>{ 'A', 4, 'Danish', 1, 'Receive critical dates from title company' },
    new List<Object>{ 'A', 5, 'Danish', 1, 'Log critical dates into Salesforce deal record' },
    new List<Object>{ 'A', 6, 'Danish', 2, 'Note any extensions or additional earnest money schedules' },
    // B — Earnest Money Wire
    new List<Object>{ 'B', 1, 'Danish', 1, 'Request wiring instructions from title company' },
    new List<Object>{ 'B', 2, 'Danish', 2, 'Call title company to verbally verify wiring instructions (anti-fraud)' },
    new List<Object>{ 'B', 3, 'Danish', 2, 'Send wire request to accounting with verified instructions' },
    new List<Object>{ 'B', 4, 'Accounting', 3, 'Confirm wire sent and mark task complete' },
    new List<Object>{ 'B', 5, 'Danish', 3, 'Update deal record: Earnest Money Sent = Yes' },
    // C — Property Condition Report (BBG)
    new List<Object>{ 'C', 1, 'Danish', 1, 'Email BBG team to request bid for Property Condition Report' },
    new List<Object>{ 'C', 2, 'Danish', 3, 'Review and approve BBG bid' },
    new List<Object>{ 'C', 3, 'Danish', 4, 'Sign BBG engagement contract and return' },
    new List<Object>{ 'C', 4, 'Danish', 5, 'Coordinate BBG site visit with seller' },
    new List<Object>{ 'C', 5, 'Danish', 28, 'Receive completed Property Condition Report from BBG' },
    new List<Object>{ 'C', 6, 'Danish', 29, 'Review PCR - note repairs, capital expenses, structural issues' },
    new List<Object>{ 'C', 7, 'Danish', 30, 'Upload PCR to deal document folder' },
    // D — LPRD Cash Flow Verification
    new List<Object>{ 'D', 1, 'Danish', 2, 'Engage LPRD and send due diligence materials' },
    new List<Object>{ 'D', 2, 'Danish', 2, 'Send LPRD leases, rent roll, financial model, seller NOI' },
    new List<Object>{ 'D', 3, 'Danish', 2, 'Request LPRD to build independent cash flow model' },
    new List<Object>{ 'D', 4, 'Danish', 28, 'Receive and review LPRD cash flow model vs seller NOI' },
    new List<Object>{ 'D', 5, 'Danish', 29, 'Upload LPRD report to deal folder' },
    // E — Appraisal
    new List<Object>{ 'E', 1, 'Danish', 3, 'Select and engage appraisal vendor' },
    new List<Object>{ 'E', 2, 'Danish', 5, 'Schedule appraisal and coordinate site access with seller' },
    new List<Object>{ 'E', 3, 'Danish', 5, 'Send appraisal vendor financial models and deal details' },
    new List<Object>{ 'E', 4, 'Danish', 28, 'Receive completed appraisal report' },
    new List<Object>{ 'E', 5, 'Danish', 29, 'Review appraisal - confirm valuation supports underwriting' },
    new List<Object>{ 'E', 6, 'Danish', 29, 'Upload appraisal to deal folder' },
    // F — Loan Package & Financing [FINANCING ONLY]
    new List<Object>{ 'F', 1, 'Danish', 3, 'Build loan package: cash flow model, budget, rent roll, target proceeds' },
    new List<Object>{ 'F', 2, 'Danish', 5, 'Send loan package to all bankers on bankers list' },
    new List<Object>{ 'F', 3, 'Danish', 7, 'Follow up with bankers - confirm receipt of package' },
    new List<Object>{ 'F', 4, 'Danish', 16, 'Receive and compare term sheets from bankers' },
    new List<Object>{ 'F', 5, 'CFO', 18, 'Review term sheets with CFO - select preferred lender' },
    new List<Object>{ 'F', 6, 'Danish', 22, 'Sign selected term sheet' },
    new List<Object>{ 'F', 7, 'Legal', 24, 'Work with legal to form entity (LLC/LP) for the deal' },
    new List<Object>{ 'F', 8, 'Accounting', 26, 'Open bank account at lender bank for the deal entity' },
    new List<Object>{ 'F', 9, 'Accounting', 26, 'Select bank account type' },
    new List<Object>{ 'F', 10, 'Danish', 28, 'Obtain wiring instructions from lender bank' },
    new List<Object>{ 'F', 11, 'Legal', 28, 'Send executed company agreement to lender bank' },
    new List<Object>{ 'F', 12, 'Accounting', 30, 'Set up auto loan payment (CRITICAL - frequently missed)' },
    // G — Insurance
    new List<Object>{ 'G', 1, 'Danish', 1, 'Send insurance quote request to DPEG insurance broker' },
    new List<Object>{ 'G', 2, 'Danish', 2, 'Provide broker estimated loan amount, coverage, binding deadline' },
    new List<Object>{ 'G', 3, 'Danish', 5, 'Request quotes from multiple brokers (compare pricing)' },
    new List<Object>{ 'G', 4, 'Danish', 20, 'Review and compare insurance quotes' },
    new List<Object>{ 'G', 5, 'Danish', 25, 'Select and bind insurance policy' },
    new List<Object>{ 'G', 6, 'Danish', 26, 'Upload insurance documents to deal folder' },
    // H — Entity Formation & Investor Relations (FES)
    new List<Object>{ 'H', 1, 'Danish', 5, 'Internal discussion with FES - determine entity structure' },
    new List<Object>{ 'H', 2, 'Legal', 14, 'Legal department forms the deal entity' },
    new List<Object>{ 'H', 3, 'FES', 20, 'FES prepares investor launch deck / pitch presentation' },
    new List<Object>{ 'H', 4, 'FES', 25, 'FES launches deal to investors - calls for capital commitments' },
    new List<Object>{ 'H', 5, 'FES', 55, 'Confirm equity capital is fully committed and deposited' },
    // H2 — Tenant Interviews & Estoppels
    new List<Object>{ 'H2', 1, 'Danish', 7, 'Request tenant contact info from sales broker' },
    new List<Object>{ 'H2', 2, 'Danish', 12, 'Schedule and conduct tenant interviews' },
    new List<Object>{ 'H2', 3, 'Danish', 12, 'Request estoppels from seller (verifies lease accuracy)' },
    new List<Object>{ 'H2', 4, 'Danish', 28, 'Review estoppels - confirm lease terms match representations' },
    new List<Object>{ 'H2', 5, 'Prop. Mgmt.', 60, 'Collect SNDAs from tenants via property management' },
    // I — Pre-Closing & Closing
    new List<Object>{ 'I', 1, 'Danish', 53, 'Request closing statement from title company' },
    new List<Object>{ 'I', 2, 'Danish', 55, 'Review closing statement: taxes, rental income, expenses, tax cert' },
    new List<Object>{ 'I', 3, 'Legal', 56, 'Resolve any discrepancies with seller/buyer' },
    new List<Object>{ 'I', 4, 'Danish', 57, 'Send closing statement to legal for final approval' },
    new List<Object>{ 'I', 5, 'Danish', 58, 'Obtain authorized signatures from CEO / authorized signatory' },
    new List<Object>{ 'I', 6, 'Danish', 58, 'Request wiring instructions from title company for closing funds' },
    new List<Object>{ 'I', 7, 'Danish', 59, 'Verify wiring instructions by phone (anti-fraud)' },
    new List<Object>{ 'I', 8, 'Accounting', 59, 'Send closing wire to title company with verified instructions' },
    new List<Object>{ 'I', 9, 'Danish', 60, 'Authorize closing with title company' },
    new List<Object>{ 'I', 10, 'Danish', 60, 'Confirm closing complete - update deal stage to Closed' },
    // J — Post-Closing Checklist [Stage = Closed]
    new List<Object>{ 'J', 1, 'Danish', 60, 'Send closing announcement via WhatsApp/email to entire office' },
    new List<Object>{ 'J', 2, 'Danish', 61, 'Announce next steps to the team' },
    new List<Object>{ 'J', 3, 'Prop. Mgmt.', 63, 'Transfer all utilities to new entity' },
    new List<Object>{ 'J', 4, 'Accounting', 63, 'Set up auto loan payment at lender bank (CRITICAL)' },
    new List<Object>{ 'J', 5, 'Danish', 63, 'Upload survey to deal document folder' },
    new List<Object>{ 'J', 6, 'Danish', 63, 'Upload all insurance documents (bound policy)' },
    new List<Object>{ 'J', 7, 'Danish', 64, 'Upload rent roll' },
    new List<Object>{ 'J', 8, 'Danish', 65, 'Upload all closing documents and closing statement' },
    new List<Object>{ 'J', 9, 'Danish', 65, 'Upload tenant contact information' },
    new List<Object>{ 'J', 10, 'Danish', 67, 'File original executed documents (physical)' },
    new List<Object>{ 'J', 11, 'Prop. Mgmt.', 75, 'Set up property in AppFolio / ERP (property management software)' },
    new List<Object>{ 'J', 12, 'FES', 65, 'FES blasts investor announcement - property successfully acquired' },
    new List<Object>{ 'J', 13, 'Danish', 67, 'Notify tax litigation company (CBRE / Daniel Ambrose)' },
    new List<Object>{ 'J', 14, 'Danish', 67, 'Upload warranties (if applicable)' },
    new List<Object>{ 'J', 15, 'Accounting', 65, 'Upload all loan information to Global Cash Flow tracker' }
};

Metadata.DeployContainer container = new Metadata.DeployContainer();
for (List<Object> d : defs) {
    String letter = (String) d[0];
    Integer seq = (Integer) d[1];
    String owner = (String) d[2];
    Integer offset = (Integer) d[3];
    String subject = (String) d[4];

    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
    String devLetter = letter.replace('.', '').replace(' ', '');
    cm.fullName = 'Transaction_Task_Def.Task_Def_' + devLetter + '_' + (seq < 10 ? '0' + seq : '' + seq);
    cm.label = subject.length() > 40 ? subject.substring(0, 40) : subject;

    Map<String, Object> fv = new Map<String, Object>{
        'Group_Letter__c' => letter, 'Sequence__c' => seq, 'Subject__c' => subject,
        'Owner_Label__c' => owner, 'Due_Day_Offset__c' => offset
    };
    for (String f : fv.keySet()) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = f;
        v.value = fv.get(f);
        cm.values.add(v);
    }
    container.addMetadata(cm);
}
System.debug('Enqueued ' + defs.size() + ' task-def deploy: ' + Metadata.Operations.enqueueDeployment(container, null));
