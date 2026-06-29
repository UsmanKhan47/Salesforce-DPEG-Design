// Run each Disposition report and print its grand-total aggregate(s) to confirm
// the dashboard Metric components will display the expected KPI numbers.
for (Report r : [SELECT Id, DeveloperName FROM Report WHERE FolderName = 'Dispositions' ORDER BY DeveloperName]) {
    Reports.ReportResults res = Reports.ReportManager.runReport(r.Id, false);
    Reports.ReportFact grand = res.getFactMap().get('T!T');
    List<String> vals = new List<String>();
    for (Reports.SummaryValue sv : grand.getAggregates()) {
        vals.add(String.valueOf(sv.getLabel()));
    }
    System.debug(LoggingLevel.ERROR, r.DeveloperName + ' => ' + String.join(vals, ' | '));
}
