List<OpportunityFunnelController.OppRow> rows = OpportunityFunnelController.getRecentOpportunities();
System.debug('RECENT OPPS :: count=' + rows.size());
Integer shown = 0;
for (OpportunityFunnelController.OppRow r : rows) {
    if (shown++ >= 3) break;
    System.debug('ROW :: ' + r.name + ' | ' + r.stage + ' | ' + r.dealType + ' | asset=' + r.assetType + ' | price=' + r.price + ' | age=' + r.days + 'd');
}
