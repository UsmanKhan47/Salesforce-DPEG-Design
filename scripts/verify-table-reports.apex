// Fresh-run the two new dashboard table reports and print row counts + a sample,
// so we don't get fooled by cached dashboard snapshots.
for (Report r : [SELECT Id, DeveloperName FROM Report
                 WHERE DeveloperName IN ('NDA_Tracker_Recent','Underwriting_Outputs_Active')]) {
    Reports.ReportResults res = Reports.ReportManager.runReport(r.Id, true);
    Reports.ReportFactWithDetails fact =
        (Reports.ReportFactWithDetails) res.getFactMap().get('T!T');
    List<Reports.ReportDetailRow> rows = fact.getRows();
    System.debug('=== ' + r.DeveloperName + ' : ' + rows.size() + ' rows ===');
    for (Reports.ReportDetailRow row : rows) {
        List<String> cells = new List<String>();
        for (Reports.ReportDataCell c : row.getDataCells()) cells.add(c.getLabel());
        System.debug(String.join(cells, ' | '));
    }
}
