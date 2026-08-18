# DESIGN REQUIREMENTS

Date: 2026-08-18
Scope: two declarative-only fixes on `usman-dpeg` (Item 1 NDA Advance Stage visibility, Item 2 LOI Signed latch).
Excluded by the requester: LOI Offer Price / Offer Cap Rate numeric-entry issue (under separate live investigation).

---

## 0. VERIFICATION OF BRIEF PREMISES (read before anything else)

The brief was measured against the repo rather than restated. **Item 1 is confirmed and ready.
Item 2 has one BLOCKING contradiction** — it names a field that no automation ever sets to
`'Signed'`, so the fix as written would deploy clean and do nothing.

### CONFIRMED

| Premise | Evidence |
|---|---|
| Acquisition NDA reordered to Pending -> Received -> Signed -> Sent, 'Sent' terminal | `RecordStageAdvanceService.cls:550-554` — `NDA_ACQUISITION_NEXT_STAGE` = `{'Pending'=>'Received','Received'=>'Signed','Signed'=>'Sent'}`. Class header lines 40-45 record the 2026-08-16 user decision. |
| 'Signed' IS terminal on Disposition NDA | `RecordStageAdvanceService.cls:573-576` — `NDA_DISPOSITION_NEXT_STAGE` = `{'Not Sent'=>'Sent','Sent'=>'Signed'}`. No `'Signed'` key. Header lines 564-571 explicitly forbid harmonising the two maps. |
| FlexiPage entry 1 (Acquisition) has the stale `NE 'Signed'` | `NDA_Record_Page.flexipage-meta.xml:11-28` — `booleanFilter` `1 AND 2 AND 3`; criteria 2 is `{!Record.Status__c} NE 'Signed'`. |
| No triggers and no validation rules on `LOI__c` | `force-app/main/default/triggers/*LOI*` and `objects/LOI__c/validationRules/` are both empty — the before-save path for Item 2 is otherwise clean. |
| `LOI_Signed__c` (Checkbox) and `LOI_Signed_Date__c` (Date) exist and are manual on `Edit_LOI` | `quickActions/LOI__c.Edit_LOI.quickAction-meta.xml:50-59`. |

### 🔴 C1 — BLOCKING: Item 2 names the wrong field. `LOI_Status__c` is never set to 'Signed'.

`LOI__c` carries **two** picklists that both contain a `Signed` value, and they are deliberately
separate concerns. `LoiSelector.cls:121-123` states the rule outright:

> `Stage__c` is the Path field and is NOT `LOI_Status__c` — the approval audit writes the latter,
> this action writes the former. Widening this method to select or write `LOI_Status__c` would
> silently couple the quick action to the approval's field.

- **`Stage__c`** — the lifecycle field. Drives `LOI_Path_Acquisition` / `LOI_Path_Disposition` and
  `RecordStageAdvanceService`. Acquisition_LOI runs Draft -> Under Review -> Submitted ->
  Negotiation -> **Signed** (terminal). This is the field the **Advance Stage button writes**.
- **`LOI_Status__c`** — approval//deal vocabulary. Every writer in the repo sets something other
  than 'Signed': `ApprovalAuditService.cls:92` -> `'Approved'`; `CounterOfferService.cls:188` ->
  `'Countered'`; `OpportunityReviewService.cls:541` -> `'Draft'` at creation.
  **No automation anywhere writes `LOI_Status__c = 'Signed'`.** The value is exposed on the record
  type (`Acquisition_LOI.recordType-meta.xml:250-253`) and the field sits on the `Edit_LOI` quick
  action, so the only way it is ever reached is a human manually picking it.

**Consequence if built as briefed:** the flow fires only when someone manually selects
`LOI_Status__c = 'Signed'` in the Edit LOI modal, and does **not** fire when the LOI is actually
advanced to Signed via the Advance Stage button / Path. The stated goal — the item's own title says
"auto-populate on Signed **stage**" — would not be met, and nothing would error.

**The NDA analog confirms the intent.** `NDA_Signed_Status_Sync` keys on `NDA__c.Status__c`, which
IS the NDA's Advance-Stage field in `RecordStageAdvanceService`. Mirroring that analog on `LOI__c`
means keying on **`Stage__c`**, not `LOI_Status__c`.

➡ **DECISION REQUIRED (D1)** — see §3. This is the one thing that must be answered before Item 2
can be built.

### C2 — Item 2 will start firing Legal + IR notifications automatically

`flows/LOI_Signed_Notify.flow-meta.xml` is an **after-save** flow on `LOI__c` whose entry filter is
`LOI_Signed__c EqualTo true`, `doesRequireRecordChangedToMeetCriteria = true`,
`recordTriggerType = CreateAndUpdate` (lines 85-96). It calls `GroupNotifier` twice — `Legal_Team`
("LOI fully executed... PSA negotiation begins") and `Investor_Relations` ("prepare Offering
Memorandum").

The brief said the existing flows do not *write* these fields. That is true — but this one
**triggers on** `LOI_Signed__c`. Today the checkbox is manual, so those notifications fire when a
human ticks it. After this change they fire **automatically on stage advance**. That is a real
behaviour change crossing a module boundary into Legal and Investor Relations, so it is flagged for
explicit acknowledgement rather than assumed acceptable. The one-way latch means it fires once, not
repeatedly.

### C3 — The NDA analog does more than the brief describes; mirror the extra part

`NDA_Signed_Status_Sync` does not simply set a checkbox. It also stamps the date **through a null
guard**: decision `Needs_Signed_Date` stamps `Date_Signed__c = $Flow.CurrentDate` only when the date
`IsNull` (lines 102-123). It never overwrites an existing date and never clears it. The LOI
equivalent should carry the same guard so a manually entered `LOI_Signed_Date__c` is preserved.

Also note: the flow's `Set_Signed_False` assignment **exists in metadata but is unconnected**, and
the flow's in-root XML comment (lines 8-35) is an explicit "DO NOT finish it" banner — connecting it
would un-sign NDAs and lock deals out of the pipeline. **Recommendation: do NOT reproduce that dead
assignment in the new LOI flow.** Copying a documented trap is not consistency. The latch should be
achieved by simply having no false branch at all.

### C4 — Flow inventory correction

Only **one** flow in the repo is on `LOI__c`: `LOI_Signed_Notify`. `Counter_Offer_Notify` is on
`Counter_Offer__c` (`Create` / `RecordAfterSave`), not `LOI__c`. So the count is one, not two — and
that one is **not** unrelated, per C2.

### C5 — Item 1 introduces one instance of an already-documented residual

The two `Advance_Stage` entries on `NDA_Record_Page` are discriminated by **custom permission**, not
record type — a FlexiPage visibility rule cannot express a record-type test (documented in
`NDA__c.Is_Decline_Allowed__c`'s header, cited again in `Acquisition_LOI.recordType-meta.xml:74-77`).
`Acquisition_Deal_Actions` is granted by exactly one set (`Acquisition_Deal_Driver`) and
`Disposition_Deal_Actions` by exactly one (`Disposition_Deal_Driver`) — disjoint in the repo, but
nothing prevents assigning both to one user.

After removing `NE 'Signed'` from entry 1, a user holding **both** sets who opens a **Disposition
NDA at Status = 'Signed'** will now see the Advance Stage button (entry 1 evaluates: has
`Acquisition_Deal_Actions` ✓, Status `NE 'Declined'` ✓). Clicking it is refused server-side —
`NDA_DISPOSITION_NEXT_STAGE` has no `'Signed'` key — so this is a cosmetic/UX residual, not a data
risk. `DPEG_Disposition_Edit.permissionset-meta.xml:265-267` already records this exact residual
class: *"A user holding BOTH sets does see it; runbook 1.6 and gate G7 own that residual."* Recorded
here so it is a known consequence rather than a surprise.

### C6 — Item 1: do not "normalise" the second entry

The brief describes entry 2 as the Disposition entry with an `NE 'Signed'` exclusion. Accurate, but
incomplete: entry 2 has **three** criteria — `Disposition_Deal_Actions`, `Is_Decline_Allowed__c
EQUAL true`, and `Status__c NE 'Signed'` (lines 32-49). It must be left **byte-identical**. The two
entries are asymmetric by design; an admin tidying them into a matching shape would break the
disposition action bar.

---

## 1. WHAT WAS REQUESTED

**Item 1** — Remove the now-incorrect `Status__c NE 'Signed'` criterion from the **first
(Acquisition)** `NDA__c.Advance_Stage` entry on `NDA_Record_Page`, so the button is available for the
`Signed -> Sent` hop. Leave the second (Disposition) entry untouched. FlexiPage visibility rule only —
**no data cleanup** of acquisition NDAs currently parked on `Status = 'Sent'` under the old meaning
(explicitly deferred as a separate data-remediation item).

**Item 2** — Create a before-save flow on `LOI__c` mirroring `NDA_Signed_Status_Sync`: when the LOI
reaches Signed, set `LOI_Signed__c = true` and `LOI_Signed_Date__c = TODAY()`, as a **one-way latch**
that is never reset if the status later moves away. Suggested name `LOI_Signed_Status_Sync`.

---

## 2. 🔵 ADMIN WORK (salesforce-admin)

Both items are single-object declarative changes. No development work is required for either.

### A1 — Edit `flexipages/NDA_Record_Page.flexipage-meta.xml` (Item 1)

- In the **first** `<valueListItems>` whose `<value>` is `NDA__c.Advance_Stage` (lines 9-29):
  - Delete the second `<criteria>` block — `{!Record.Status__c}` / `NE` / `Signed` (lines 18-22).
  - Change `<booleanFilter>` from `1 AND 2 AND 3` to `1 AND 2`.
  - Retain criterion 1 (`{!$Permission.CustomPermission.Acquisition_Deal_Actions} EQUAL true`) and
    the `NE 'Declined'` criterion, which becomes criterion 2.
- **Do not touch** the second `<valueListItems>` (Disposition, lines 30-50) or the `Mark_Declined`
  entry (lines 51-66). See C6.
- No other file changes. No data changes.

### A2 — New Flow `LOI_Signed_Status_Sync` (Item 2) — **blocked on D1**

- Type: **Record-Triggered, before-save** (`triggerType = RecordBeforeSave`), object `LOI__c`,
  `recordTriggerType = CreateAndUpdate`. Matches the NDA analog exactly.
- `apiVersion` **67.0**, `status` Active, `processType` AutoLaunchedFlow (project convention per
  ARCHITECTURE.md).
- Entry/decision: when **[field per D1]** equals `Signed`:
  - Assign `LOI_Signed__c = true`.
  - Then a second decision mirroring `Needs_Signed_Date`: if `LOI_Signed_Date__c` `IsNull`, assign
    `LOI_Signed_Date__c = $Flow.CurrentDate`. Never overwrite an existing date. (C3)
- **One-way latch:** no false/default branch, and **no dead `Set_Signed_False` assignment** — the
  default connector is simply absent so the checkbox can only ever be set true. (C3)
- Record an in-root XML comment (inside `<Flow>`, never above it — a comment above the root breaks
  `sf` at source conversion) stating that the latch is deliberate and the false branch must not be
  added, and cross-referencing `NDA_Signed_Status_Sync`.
- Note in the same comment that `LOI_Signed_Notify` fires off this write (C2).

**No validation rules, no permission sets, no page-layout changes, no test classes** are included —
none were requested.

---

## 3. 🚦 BLOCKING DECISION BEFORE A2

**D1 — Which field triggers the LOI latch?**

- **Option A (recommended): `Stage__c = 'Signed'`.** This is the field the Advance Stage button and
  the Path actually write, and it is the true mirror of the NDA analog. Self-limiting to
  Acquisition_LOI with no record-type criterion needed, because the terminals stay distinct —
  acquisition ends at `Signed`, disposition at `Executed` (confirmed in
  `Stage__c.field-meta.xml:115-118`; the overlap is only mid-sequence at 'Under Review').
- **Option B (as briefed): `LOI_Status__c = 'Signed'`.** Fires only on a manual Edit LOI pick; will
  never fire on a stage advance. Choose this only if the intent really is a manual approval-side
  marker.
- **Option C:** both fields. Not recommended — `LoiSelector.cls:121-123` explicitly warns against
  coupling the two.

**D2 — Disposition LOIs (raised, not assumed).** Under Option A a disposition LOI reaching its
terminal `Executed` would **not** set `LOI_Signed__c`. Not requested, so it is out of scope — but the
asymmetry is flagged rather than silently introduced. Confirm "acquisition only" is intended.

**D3 — Acknowledge C2.** Confirm that Legal and Investor Relations receiving automatic notifications
on LOI stage advance is intended.

---

## 4. 🟢 DEVELOPMENT WORK (salesforce-developer)

**None.** Both items are declarative. No Apex, LWC, or test classes are in scope.

Note: `RecordStageAdvanceService.cls` already carries the correct maps for both items and needs **no
change** — Item 1 is purely the FlexiPage catching up to Apex. Likewise `NDA_Signed_Status_Sync`
needs no change; its latch is what makes the 2026-08-16 NDA reorder safe (class header lines 535-548).

---

## 5. 🔗 EXECUTION ORDER

1. **A1 (Item 1)** — independent, unblocked, deployable now.
2. **D1/D2/D3 answered** — blocks A2.
3. **A2 (Item 2)** — after D1.

The two items share no metadata and can deploy separately. ⚠ Per project memory, diff
`NDA_Record_Page.flexipage-meta.xml` against HEAD immediately before deploying — this tree has been
edited by concurrent sessions before, and FlexiPages are a known silent-union hazard.

---

## 6. PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR salesforce-admin — Item 1 (ready now)

```
Edit force-app/main/default/flexipages/NDA_Record_Page.flexipage-meta.xml only. Do not deploy.

In the FIRST <valueListItems> whose <value> is NDA__c.Advance_Stage (currently lines 9-29):
- Remove the <criteria> block for {!Record.Status__c} NE 'Signed'.
- Change <booleanFilter> from "1 AND 2 AND 3" to "1 AND 2".
- Keep the {!$Permission.CustomPermission.Acquisition_Deal_Actions} EQUAL true criterion and the
  {!Record.Status__c} NE 'Declined' criterion.

Reason: RecordStageAdvanceService.NDA_ACQUISITION_NEXT_STAGE now maps 'Signed' => 'Sent'
(2026-08-16 reorder), so hiding the button at Signed hides it exactly when it is actionable.

DO NOT modify the SECOND NDA__c.Advance_Stage entry (Disposition). It has THREE criteria —
Disposition_Deal_Actions, Is_Decline_Allowed__c EQUAL true, and Status__c NE 'Signed' — and all
three are correct: 'Signed' is genuinely terminal for Disposition_NDA. Do not make the two entries
symmetrical. Do not modify the Mark_Declined entry. Do not touch any other file. No data changes.
```

### 🔵 PROMPT FOR salesforce-admin — Item 2 (hold until D1 is answered)

```
Create force-app/main/default/flows/LOI_Signed_Status_Sync.flow-meta.xml. Do not deploy.

Model it on force-app/main/default/flows/NDA_Signed_Status_Sync.flow-meta.xml — read that file's
actual XML first and follow its structure.

- Record-triggered, object LOI__c, triggerType RecordBeforeSave, recordTriggerType CreateAndUpdate.
- apiVersion 67.0, processType AutoLaunchedFlow, status Active.
- Decision: when <FIELD FROM D1> equals 'Signed' -> assign LOI_Signed__c = true.
- Then a second decision mirroring the analog's Needs_Signed_Date: if LOI_Signed_Date__c IsNull,
  assign LOI_Signed_Date__c = $Flow.CurrentDate. Never overwrite an existing date.
- ONE-WAY LATCH: no default/false connector and NO Set_Signed_False assignment at all. The NDA
  analog has an unconnected Set_Signed_False that its own XML comment marks as a hazard — do not
  reproduce it.
- Add an XML comment INSIDE the root <Flow> element (never above it) recording: the latch is
  deliberate; the false branch must never be added; and that the after-save flow LOI_Signed_Notify
  triggers on LOI_Signed__c = true and will now notify Legal_Team and Investor_Relations
  automatically as a result of this write.

Do not create validation rules, permission sets, layout changes or test classes. Do not modify
LOI_Signed_Notify or RecordStageAdvanceService.
```

### 🟢 PROMPT FOR salesforce-developer

None — no development work in scope.
