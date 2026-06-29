Set<String> keep = new Set<String>{
    'Sienna Town Center',
    'Westheimer C-Stores x9',
    'Heights Apartments',
    'Texas City Self-Storage',
    'Beltway Office Park'
};
List<Property_Asset__c> toDelete = [
    SELECT Id, Name FROM Property_Asset__c WHERE Name NOT IN :keep
];
System.debug('Deleting ' + toDelete.size() + ' old Property_Asset__c records.');
delete toDelete;
