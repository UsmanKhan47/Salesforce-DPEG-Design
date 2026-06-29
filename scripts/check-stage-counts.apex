for (OpportunityFunnelController.StageCount sc : OpportunityFunnelController.getStageCounts()) {
    System.debug('STAGE :: ' + sc.label + ' = ' + sc.count);
}
