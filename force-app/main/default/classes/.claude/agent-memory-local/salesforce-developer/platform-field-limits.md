# Platform limits measured against the org (not recalled)

All verified by anonymous Apex on DPEG-Acq-5, 2026-07-17.

## Task.Subject
- `Task.Subject.getDescribe().getLength()` = **255**, type `COMBOBOX`
- 255 chars → inserts fine. 256 → `DmlException: Subject: data value too large: ... (max length=255)`
- It **throws**, it does not silently truncate.

## Salesforce Date valid range = 1700-01-01 .. 4000-12-31
- `1700-01-01` and `4000-12-31` insert fine
- `1699-12-31`, `4001-01-01`, `9999-01-01` → `DmlException: FIELD_INTEGRITY_EXCEPTION,
  Due Date Only: invalid date: ... [ActivityDate]`
- Apex will happily *construct* `Date.newInstance(9999,1,1)`; only the DML rejects it.

## Why this is useful: forcing a failure at a CHOSEN DML
To prove a savepoint rollback undoes **committed** work you need the Nth DML to fail while
DML 1..N-1 succeed. Useful levers:
- **out-of-range Date** — clean, targets exactly the record carrying that date
- **over-length text** — only if no server-side guard intercepts it first

Non-levers worth knowing:
- An **unrestricted** picklist accepts *any* value silently — useless as a failure lever.
  Check for `<restricted>true</restricted>` in the field meta before trying.
  (`Ball_In_Court__c` on both `Lease_Inquiry__c` and `Lease_Activity__c` is unrestricted.)

## Pairing rule
A test asserting "state unchanged after rollback" is **vacuous** unless the value it attempts
to write genuinely differs from the pre-call value, AND a sibling control test proves that
same payload commits the earlier DMLs. Otherwise a failure at DML #1 satisfies the identical
assertions.
