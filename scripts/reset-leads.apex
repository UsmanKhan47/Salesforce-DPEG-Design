// Dev utility: clear seeded leads so they can be re-imported with channel (LeadSource) values.
delete [SELECT Id FROM Lead];
