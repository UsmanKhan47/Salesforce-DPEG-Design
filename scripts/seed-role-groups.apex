// Seeds the role-based public groups + placeholder users that acquisition
// lifecycle notifications and approval processes target. Idempotent: safe to
// re-run; existing users/groups/memberships are left alone.
//
// Scratch-org license reality (checked on DPEG-Acq-3):
//   - 'Salesforce' (full): 2 seats, 1 used by the admin -> ONE seat for Nikhil,
//     who must approve Opportunities (approvers need full object access).
//   - 'Ali' is NOT created: the running scratch-org admin stands in for Ali
//     (the existing LOI_Approval process already uses the admin as approver).
//   - 'Salesforce Platform': 3 seats -> Nick, JR, Rahila (notification roles).
//   - 'Chatter Free': plentiful -> Danish, Faiz, Luke (notification-only).
//
// Usernames are FIXED (not org-suffixed) because approval-process metadata
// references approvers by username. If a new scratch org collides with a
// still-live older org on these usernames, retire the old org first.
//
// The running user (scratch-org admin) is added to every group so all
// lifecycle notifications are visible in one bell during demos.

// role -> {username, first, last, profile}
Map<String, List<String>> userDefs = new Map<String, List<String>>{
    'nikhil' => new List<String>{ 'nikhil.principal@dpeg-acq.demo', 'Nikhil', 'Dhanani', 'Standard User' },
    'nick'   => new List<String>{ 'nick.acq@dpeg-acq.demo',         'Nick',   'Acquisitions', 'Standard Platform User' },
    'jr'     => new List<String>{ 'jr.acq@dpeg-acq.demo',           'JR',     'Acquisitions', 'Standard Platform User' },
    'rahila' => new List<String>{ 'rahila.legal@dpeg-acq.demo',     'Rahila', 'Legal', 'Standard Platform User' },
    'danish' => new List<String>{ 'danish.dd@dpeg-acq.demo',        'Danish', 'Diligence', 'Chatter Free User' },
    'faiz'   => new List<String>{ 'faiz.ir@dpeg-acq.demo',          'Faiz',   'InvestorRelations', 'Chatter Free User' },
    'luke'   => new List<String>{ 'luke.ir@dpeg-acq.demo',          'Luke',   'InvestorRelations', 'Chatter Free User' }
};

// group DeveloperName -> label, member role keys ('admin' = running user, always added anyway)
Map<String, List<String>> groupDefs = new Map<String, List<String>>{
    'Acquisitions_Team'  => new List<String>{ 'Acquisitions Team', 'nikhil', 'nick', 'jr' },
    'Principals'         => new List<String>{ 'Principals', 'nikhil' },
    'LOI_Panel'          => new List<String>{ 'LOI Panel', 'nick', 'jr', 'rahila' },
    'Legal_Team'         => new List<String>{ 'Legal Team', 'rahila' },
    'Investor_Relations' => new List<String>{ 'Investor Relations', 'faiz', 'luke' },
    'Due_Diligence'      => new List<String>{ 'Due Diligence', 'danish' },
    'Transactions_Team'  => new List<String>{ 'Transactions Team', 'danish' }
};

Map<String, Id> profileIdByName = new Map<String, Id>();
for (Profile p : [SELECT Id, Name FROM Profile
                  WHERE Name IN ('Standard User', 'Standard Platform User', 'Chatter Free User')]) {
    profileIdByName.put(p.Name, p.Id);
}

// 1. Ensure placeholder users (one at a time: a license shortage on one tier
//    must not block the others).
Set<String> usernames = new Set<String>();
for (List<String> def : userDefs.values()) { usernames.add(def[0]); }
Map<String, Id> userIdByUsername = new Map<String, Id>();
for (User u : [SELECT Id, Username FROM User WHERE Username IN :usernames]) {
    userIdByUsername.put(u.Username, u.Id);
}
for (String role : userDefs.keySet()) {
    List<String> def = userDefs.get(role);
    if (userIdByUsername.containsKey(def[0])) { continue; }
    Id profileId = profileIdByName.get(def[3]);
    if (profileId == null) {
        System.debug(LoggingLevel.WARN, 'Profile missing for ' + role + ': ' + def[3]);
        continue;
    }
    User u = new User(
        Username = def[0],
        FirstName = def[1],
        LastName = def[2],
        Email = def[0].replace('.demo', '.demo.invalid'),
        Alias = (def[1].replaceAll('[^a-zA-Z]', '').toLowerCase() + role).left(8),
        ProfileId = profileId,
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        TimeZoneSidKey = 'America/Chicago'
    );
    try {
        insert u;
        userIdByUsername.put(u.Username, u.Id);
    } catch (DmlException e) {
        System.debug(LoggingLevel.WARN, 'Skipped user ' + def[0] + ': ' + e.getDmlMessage(0));
    }
}
System.debug('Placeholder users present: ' + userIdByUsername.size() + ' of ' + userDefs.size());

// 2. Ensure groups.
Map<String, Id> groupIdByName = new Map<String, Id>();
for (Group g : [SELECT Id, DeveloperName FROM Group WHERE Type = 'Regular' AND DeveloperName IN :groupDefs.keySet()]) {
    groupIdByName.put(g.DeveloperName, g.Id);
}
List<Group> groupsToInsert = new List<Group>();
for (String devName : groupDefs.keySet()) {
    if (!groupIdByName.containsKey(devName)) {
        groupsToInsert.add(new Group(Name = groupDefs.get(devName)[0], DeveloperName = devName, Type = 'Regular'));
    }
}
if (!groupsToInsert.isEmpty()) {
    insert groupsToInsert;
    for (Group g : groupsToInsert) { groupIdByName.put(g.DeveloperName, g.Id); }
}

// 3. Ensure memberships (available role users + the running admin for demo visibility).
Set<String> existing = new Set<String>();
for (GroupMember gm : [SELECT GroupId, UserOrGroupId FROM GroupMember WHERE GroupId IN :groupIdByName.values()]) {
    existing.add(gm.GroupId + ':' + gm.UserOrGroupId);
}
List<GroupMember> members = new List<GroupMember>();
for (String devName : groupDefs.keySet()) {
    Id gId = groupIdByName.get(devName);
    List<String> def = groupDefs.get(devName);
    Set<Id> wanted = new Set<Id>{ UserInfo.getUserId() };
    for (Integer i = 1; i < def.size(); i++) {
        Id uId = userIdByUsername.get(userDefs.get(def[i])[0]);
        if (uId != null) { wanted.add(uId); }
    }
    for (Id uId : wanted) {
        if (!existing.contains(gId + ':' + uId)) {
            members.add(new GroupMember(GroupId = gId, UserOrGroupId = uId));
        }
    }
}
// Partial success: some licenses (e.g. Chatter Free) cannot join public groups.
// Those roles are covered by the admin's membership in every group.
Integer added = 0;
if (!members.isEmpty()) {
    Database.SaveResult[] results = Database.insert(members, false);
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            added++;
        } else {
            System.debug(LoggingLevel.WARN, 'Skipped membership ' + members[i].UserOrGroupId +
                ' in ' + members[i].GroupId + ': ' + results[i].getErrors()[0].getMessage());
        }
    }
}
System.debug('Groups ready: ' + groupIdByName.size() + ', new memberships: ' + added);
