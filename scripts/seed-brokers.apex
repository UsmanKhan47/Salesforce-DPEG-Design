// Seed broker-firm Accounts and assign deals to them so the Broker Leaderboard
// (Opportunities grouped by Account) matches the prototype: 8 / 6 / 4 / 2 deals.
List<Account> brokers = new List<Account>{
    new Account(Name = 'Marcus & Millichap', Type = 'Broker Firm'),
    new Account(Name = 'CBRE',               Type = 'Broker Firm'),
    new Account(Name = 'JLL',                Type = 'Broker Firm'),
    new Account(Name = 'Colliers',           Type = 'Broker Firm')
};
insert brokers;

Map<String, Id> byName = new Map<String, Id>();
for (Account a : brokers) {
    byName.put(a.Name, a.Id);
}

// Deals per broker firm, in display order.
List<String> firms  = new List<String>{ 'Marcus & Millichap', 'CBRE', 'JLL', 'Colliers' };
List<Integer> deals = new List<Integer>{ 8, 6, 4, 2 };

// Pull unassigned active deals from the seeded pipeline (20 needed).
List<Opportunity> pool = [
    SELECT Id FROM Opportunity
    WHERE AccountId = null AND StageName != 'Dead/Pass'
    ORDER BY CreatedDate
    LIMIT 20
];

List<Opportunity> toUpdate = new List<Opportunity>();
Integer idx = 0;
for (Integer f = 0; f < firms.size(); f++) {
    Id acctId = byName.get(firms[f]);
    for (Integer i = 0; i < deals[f]; i++) {
        Opportunity o = pool[idx++];
        o.AccountId = acctId;
        toUpdate.add(o);
    }
}
update toUpdate;
System.debug('Created ' + brokers.size() + ' broker firms, assigned ' + toUpdate.size() + ' deals.');
