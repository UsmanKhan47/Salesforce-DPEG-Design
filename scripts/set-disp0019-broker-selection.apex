Disposition__c d = new Disposition__c(
    Id = 'a0Ciw000004Ok1zEAC',
    Disposition_Stage__c = 'Broker Selection'
);
update d;
System.debug(LoggingLevel.ERROR, 'Updated DISP-0019 stage to Broker Selection');
