# NDA Advance Stage Button Fix + LOI Signed Status Latch (with Notification Pause)

**Date:** 2026-08-18
**Author:** Documentation Agent
**Status:** Both items deployed to `usman-dpeg`, declarative only (no Apex, LWC, or test classes touched).

---

## 📋 Overview

### Original Request

Two independent, declarative-only fixes, sourced from `agent-output/design-requirements.md`:

> **Item 1** — Remove the now-incorrect `Status__c NE 'Signed'` criterion from the first
> (Acquisition) `NDA__c.Advance_Stage` entry on `NDA_Record_Page`, so the button is available for the
> `Signed -> Sent` hop. Leave the second (Disposition) entry untouched. FlexiPage visibility rule
> only — no data cleanup of acquisition NDAs currently parked on `Status = 'Sent'` under the old
> meaning.
>
> **Item 2** — Create a before-save flow on `LOI__c` mirroring `NDA_Signed_Status_Sync`: when the
> LOI reaches Signed, set `LOI_Signed__c = true` and `LOI_Signed_Date__c = TODAY()`, as a one-way
> latch that is never reset if the status later moves away. Suggested name
> `LOI_Signed_Status_Sync`.

Item 2 as originally briefed named the wrong field (`LOI_Status__c`, not `Stage__c`) — see *Key
Design Decisions* below for why the design pass caught and corrected this before any flow was built.

### Business Objective

Both fixes remove a mismatch between a 2026-08-16 stage-sequence decision and the metadata that was
supposed to reflect it:

- **Item 1** exists because the Acquisition NDA's stage sequence was reordered on 2026-08-16
  (`'Signed' -> 'Sent'` became the new terminal hop), but nobody updated the Advance Stage button's
  own visibility rule to match — it kept hiding the button at exactly the moment a user needed it.
- **Item 2** exists because `LOI__c` had no equivalent of the NDA object's `LOI_Signed__c` auto-sync
  — the field existed but only a human manually ticking it in the Edit LOI modal ever set it, so
  it did not reliably reflect the LOI's actual signed state as driven by the Advance Stage button /
  Path.

### Summary

Item 1 is a single `booleanFilter`/`criteria` edit to one existing FlexiPage. Item 2 is a brand-new
before-save flow, `LOI_Signed_Status_Sync`, built as a close mirror of the existing
`NDA_Signed_Status_Sync` pattern — same one-way-latch shape, same null-guarded date stamp — but keyed
on `Stage__c` rather than the originally-briefed `LOI_Status__c`, a correction made during design
after investigation showed the latter is never written to `'Signed'` by any automation. As a direct
and necessary consequence of Item 2, the existing after-save notification flow `LOI_Signed_Notify`
was deliberately deactivated in the same change, to prevent it from starting to auto-fire Legal/IR
notifications on every routine stage advance.

---

## 🏗️ Components Created / Modified

### Admin Components (Declarative)

#### FlexiPages

| FlexiPage | Change |
|-----------|--------|
| `NDA_Record_Page` | First (Acquisition) `NDA__c.Advance_Stage` `<valueListItems>` entry: removed the `{!Record.Status__c} NE 'Signed'` `<criteria>` block; `<booleanFilter>` changed from `1 AND 2 AND 3` to `1 AND 2`. Second (Disposition) entry and the `Mark_Declined` entry are byte-identical to before — not touched. |

#### Flows

| Flow | Change |
|------|--------|
| `LOI_Signed_Status_Sync` | **New.** Before-save, record-triggered on `LOI__c`. Sets `LOI_Signed__c = true` when `Stage__c = 'Signed'`; then, if `LOI_Signed_Date__c` is blank, stamps it to `$Flow.CurrentDate`. One-way latch — no false/default branch, no `Set_Signed_False`-style assignment at all. |
| `LOI_Signed_Notify` | **Deactivated (paused), not deleted.** `<status>` changed from `Active` to `Draft`; logic inside the flow is unchanged. |

#### Flow Definitions

| Flow Definition | Change |
|------------------|--------|
| `LOI_Signed_Notify` | `<activeVersionNumber>` removed — this is the element that actually deactivates an already-active flow via Metadata API deploy (redeploying the flow body alone with `<status>Draft</status>` would only add a new inactive version and leave the previously-active version live). |

Both `LOI_Signed_Notify` files carry in-XML instructions for reversal — see *Reactivation* below.

#### Not touched, and deliberately so

- `RecordStageAdvanceService.cls` — already carried the correct `NDA_ACQUISITION_NEXT_STAGE` /
  `NDA_DISPOSITION_NEXT_STAGE` / LOI stage maps before this change; Item 1 is purely the FlexiPage
  catching up to Apex that was already correct.
- The second (Disposition) `NDA__c.Advance_Stage` FlexiPage entry — its own `Status__c NE 'Signed'`
  criterion is correct and stays, because `'Signed'` genuinely is terminal for `Disposition_NDA`
  (`RecordStageAdvanceService.NDA_DISPOSITION_NEXT_STAGE` has no `'Signed'` key).
- No validation rules, permission sets, page-layout changes, or test classes for either item — none
  were requested, and neither item touches Apex.

### Development Components (Code)

**None.** Both items are declarative only.

---

## 🔑 Key Design Decisions and Rationale

Pulled from the design pass's own investigation (`agent-output/design-requirements.md` findings
C1–C6) and from the in-XML comments carried in the deployed metadata itself.

### C1 (blocking) — Item 2 as briefed named the wrong field, and would have deployed and done nothing

`LOI__c` carries two separate picklists that both contain a `'Signed'` value:

- **`Stage__c`** — the lifecycle field. Drives `LOI_Path_Acquisition` / `LOI_Path_Disposition` and
  `RecordStageAdvanceService`. This is the field the **Advance Stage button writes**.
  Acquisition_LOI's sequence is `Draft -> Under Review -> Submitted -> Negotiation -> Signed`
  (terminal).
- **`LOI_Status__c`** — a separate approval/deal vocabulary field. Every writer of it in the repo
  sets something other than `'Signed'` (`'Approved'`, `'Countered'`, `'Draft'`); it is otherwise only
  reachable by a human manually picking it in the `Edit_LOI` quick action.

`LoiSelector.cls:121-123` states the distinction outright as a standing rule: *"`Stage__c` is the
Path field and is NOT `LOI_Status__c` — the approval audit writes the latter, this action writes the
former. Widening this method to select or write `LOI_Status__c` would silently couple the quick
action to the approval's field."*

Had Item 2 been built against `LOI_Status__c` as originally briefed, it would have deployed cleanly
and passed review, but would only ever have fired on a manual Edit LOI pick — never on the ordinary
Advance Stage button / Path progression, which is what the item's own stated goal ("auto-populate on
Signed **stage**") actually needed. The NDA analog itself confirms the intended shape:
`NDA_Signed_Status_Sync` keys on `NDA__c.Status__c`, which **is** the NDA's own Advance-Stage field —
the true LOI mirror of that is `Stage__c`, not `LOI_Status__c`. This was resolved as **decision D1**
before any flow was built, in favor of `Stage__c`.

### D2 — Disposition LOIs are intentionally out of scope, not silently forgotten

Keying on `Stage__c = 'Signed'` means a Disposition LOI reaching its own terminal `Stage__c` value —
`'Executed'`, a distinct string — will never set `LOI_Signed__c`. This asymmetry was not requested
and was flagged rather than silently introduced; the flow is Acquisition-only **by construction** (no
record-type criterion needed), because the two record types' terminal values never collide.

### D3 — the notify-flow pause was a necessary, deliberate side effect, not scope creep

`LOI_Signed_Notify` is an **after-save** flow whose entry filter is `LOI_Signed__c EqualTo true`,
`doesRequireRecordChangedToMeetCriteria = true`, `recordTriggerType = CreateAndUpdate`. It calls
`GroupNotifier` twice — `Legal_Team` ("LOI fully executed... PSA negotiation begins") and
`Investor_Relations` ("prepare Offering Memorandum"). Before this change, `LOI_Signed__c` was manual,
so these notifications only ever fired when a human ticked the checkbox by hand. Once
`LOI_Signed_Status_Sync` starts setting that checkbox automatically on every ordinary stage advance
to `'Signed'`, leaving `LOI_Signed_Notify` active would have made Legal and Investor Relations start
receiving automatic notifications on every routine Acquisition LOI signing — a real behaviour change
crossing into two other teams' workflows, which was explicitly **not** wanted at this time (design
decision D3). Deactivating the notify flow in the same change was the only way to ship the latch
without also shipping that unwanted side effect. The one-way latch on `LOI_Signed__c` means this
would fire once per LOI, not repeatedly — but "once, automatically, for every deal" was still judged
a decision that needed to be made deliberately rather than inherited as a side effect.

### The one-way latch pattern — mirrored, with one deliberate improvement

`NDA_Signed_Status_Sync` (the existing analog) does more than a simple checkbox set: its
`Needs_Signed_Date` decision stamps `Date_Signed__c = $Flow.CurrentDate` only when the date `IsNull`
— it never overwrites or clears an existing date. `LOI_Signed_Status_Sync` reproduces that exact
guard for `LOI_Signed_Date__c`.

One thing was **not** mirrored, deliberately. `NDA_Signed_Status_Sync` carries a
`Set_Signed_False` assignment that exists in its metadata but is **unconnected** — the `Is_Signed`
decision's default branch has a `<defaultConnectorLabel>` but no `<defaultConnector>`, so nothing
ever routes to it. That flow's own in-root XML comment (added 2026-08-16, after the NDA sequence
reversal made the unreachable assignment newly hazardous) flags this as a trap: a future editor who
sees an unconnected assignment sitting on the canvas may "finish the job" by wiring it up, which
would un-sign NDAs on every stage move away from `'Signed'` and lock deals out of the pipeline.
`LOI_Signed_Status_Sync` avoids the trap at its root by never defining the false-branch assignment at
all — there is nothing on its canvas inviting a future "fix." The latch is achieved purely by the
`Is_Signed` decision having no default connector.

### Field naming precision: `Stage__c` vs `LOI_Status__c` is the same defect class already
documented elsewhere in this codebase

This is the same shape of error flagged in the LOI/PSA stage-retirement work
(`docs/2026-08-15-retire-loi-psa-legacy-stage-values.md`) — a terminal/branch-state field name that
looks interchangeable with a sibling field but is not. Here it was caught before deployment rather
than discovered as a defect afterward, specifically because the design pass verified the brief's
field name against `LoiSelector.cls`'s own header comment rather than accepting the brief's field
choice at face value.

---

## 📁 File Locations

| Component | Path |
|-----------|------|
| NDA record page (Item 1) | `force-app/main/default/flexipages/NDA_Record_Page.flexipage-meta.xml` |
| New LOI signed-sync flow (Item 2) | `force-app/main/default/flows/LOI_Signed_Status_Sync.flow-meta.xml` |
| Existing NDA signed-sync flow (the analog Item 2 mirrors) | `force-app/main/default/flows/NDA_Signed_Status_Sync.flow-meta.xml` |
| Notification flow, deactivated (Item 2 consequence) | `force-app/main/default/flows/LOI_Signed_Notify.flow-meta.xml` |
| Flow definition, active version removed | `force-app/main/default/flowDefinitions/LOI_Signed_Notify.flowDefinition-meta.xml` |
| `LOI__c.Stage__c` field (the field Item 2 keys on) | `force-app/main/default/objects/LOI__c/fields/Stage__c.field-meta.xml` |
| `LOI__c.LOI_Signed__c` field | `force-app/main/default/objects/LOI__c/fields/LOI_Signed__c.field-meta.xml` |
| `LOI__c.LOI_Signed_Date__c` field | `force-app/main/default/objects/LOI__c/fields/LOI_Signed_Date__c.field-meta.xml` |
| Field-naming rule cited for D1 | `force-app/main/default/classes/LoiSelector.cls` (lines ~113-134) |
| Stage-advance maps (unchanged, already correct) | `force-app/main/default/classes/RecordStageAdvanceService.cls` (`NDA_ACQUISITION_NEXT_STAGE` ~line 550, `NDA_DISPOSITION_NEXT_STAGE` ~line 573) |
| Design requirements (source of C1-C6, D1-D3) | `agent-output/design-requirements.md` |

---

## ⚙️ Configuration Details

### Item 1 — `NDA_Record_Page`, first `NDA__c.Advance_Stage` entry, final state

```xml
<value>NDA__c.Advance_Stage</value>
<visibilityRule>
    <booleanFilter>1 AND 2</booleanFilter>
    <criteria>
        <leftValue>{!$Permission.CustomPermission.Acquisition_Deal_Actions}</leftValue>
        <operator>EQUAL</operator>
        <rightValue>true</rightValue>
    </criteria>
    <criteria>
        <leftValue>{!Record.Status__c}</leftValue>
        <operator>NE</operator>
        <rightValue>Declined</rightValue>
    </criteria>
</visibilityRule>
```

The second (Disposition) entry, confirmed unchanged, still carries all three of its original
criteria (`Disposition_Deal_Actions`, `Is_Decline_Allowed__c EQUAL true`, `Status__c NE 'Signed'`)
under `booleanFilter` `1 AND 2 AND 3`.

### Item 2 — `LOI_Signed_Status_Sync` flow, final state

- **Trigger:** `RecordBeforeSave`, `LOI__c`, `recordTriggerType = CreateAndUpdate`, `apiVersion 67.0`,
  `processType AutoLaunchedFlow`, `status Active`.
- **`Is_Signed` decision:** `$Record.Stage__c EqualTo 'Signed'` -> `Set_Signed_True`. No default
  connector.
- **`Set_Signed_True` assignment:** `$Record.LOI_Signed__c = true` -> continues to `Needs_Signed_Date`.
- **`Needs_Signed_Date` decision:** `$Record.LOI_Signed_Date__c IsNull` -> `Stamp_Signed_Date`. No
  default connector (an already-populated date is left alone).
- **`Stamp_Signed_Date` assignment:** `$Record.LOI_Signed_Date__c = $Flow.CurrentDate`.

### Item 2 consequence — `LOI_Signed_Notify`, final state

- `flows/LOI_Signed_Notify.flow-meta.xml`: `<status>Draft</status>` (was `Active`). All flow logic
  (the `Notify_Legal` -> `Notify_IR` `GroupNotifier` action-call chain, the
  `LOI_Signed__c EqualTo true` after-save entry filter) is byte-identical to before.
- `flowDefinitions/LOI_Signed_Notify.flowDefinition-meta.xml`: contains only its in-root XML comment
  — no `<activeVersionNumber>` element, which is what actually deactivates the previously-active
  version in the org.

---

## 🔄 Data Flow

### Item 1 — Acquisition NDA reaching Signed

```
User clicks Advance Stage on an Acquisition NDA at Status = 'Signed'
        │
        ▼
FlexiPage visibility rule (NOW: 1 AND 2, permission + NE 'Declined')  → button IS shown
        │
        ▼
RecordStageAdvanceService.NDA_ACQUISITION_NEXT_STAGE['Signed'] = 'Sent'  → advance succeeds
```

Before this fix, the same click showed no button at all (the removed third criterion,
`Status__c NE 'Signed'`, evaluated false and hid it) even though the Apex-side map had already been
willing to advance the record since the 2026-08-16 reorder.

### Item 2 — Acquisition LOI reaching Signed

```
User clicks Advance Stage (or Path) on an Acquisition LOI, Stage__c → 'Signed'
        │
        ▼  (before-save, same transaction)
LOI_Signed_Status_Sync: Is_Signed → Set_Signed_True (LOI_Signed__c = true)
        │
        ▼
Needs_Signed_Date: LOI_Signed_Date__c IsNull? → Stamp_Signed_Date ($Flow.CurrentDate)
        │
        ▼
Record commits with LOI_Signed__c = true, LOI_Signed_Date__c populated
        │
        ▼  (would fire here, but is currently PAUSED)
LOI_Signed_Notify (after-save, Draft/inactive) — Notify_Legal, Notify_IR GroupNotifier calls
```

The bottom leg is intentionally broken today: the after-save flow exists, is wired correctly, and
would fire automatically the moment it is reactivated — but does not fire while `Draft`.

---

## 🧪 Testing

**No `salesforce-unit-testing` or `salesforce-code-review` agent was invoked for this change** — it
is declarative metadata only (a FlexiPage edit and two Flow-layer changes), which is outside the
scope of those agents per the project workflow. No Apex or LWC was created or modified.

---

## 🔒 Security

No permission sets, sharing rules, profile changes, or new custom fields were part of either item.
Both fields Item 2 writes (`LOI_Signed__c`, `LOI_Signed_Date__c`) already existed and were already
writable via the `Edit_LOI` quick action; the flow runs before-save in system context and requires no
additional FLS grant.

---

## 📝 Notes & Considerations

### Reactivation of `LOI_Signed_Notify`

Both `LOI_Signed_Notify.flow-meta.xml` and its paired `LOI_Signed_Notify.flowDefinition-meta.xml`
carry in-XML "TO REACTIVATE" instructions: set `<status>` back to `Active` in the flow body **and**
restore `<activeVersionNumber>` in the FlowDefinition — both must change together, since a Draft-only
redeploy would add a new inactive version and leave the previously-active version untouched, while an
`activeVersionNumber`-only restore without the flow body's own `<status>` would leave the two files
internally inconsistent for the next reader. Per the in-XML comments, reactivating requires
re-deciding how the Legal/IR notification should be scoped or gated (e.g. batched, deal-size-gated,
or otherwise narrowed) — simply flipping the switch back resumes the exact automatic-notification
behaviour this pause exists to prevent.

### Known residual — Item 1 makes an already-documented cross-permission-set scenario reachable on
one more NDA state

The two `Advance_Stage` FlexiPage entries are discriminated by custom permission
(`Acquisition_Deal_Actions` / `Disposition_Deal_Actions`), not record type — a FlexiPage visibility
rule cannot express a record-type test. The two permissions are granted by disjoint permission sets
today (`Acquisition_Deal_Driver` / `Disposition_Deal_Driver`), but nothing in the repo prevents a user
from being assigned both. After this change, a user holding **both** sets who opens a
**Disposition** NDA at `Status = 'Signed'` will now see the Advance Stage button (the first entry's
criteria are satisfied: has `Acquisition_Deal_Actions`, `Status NE 'Declined'`). Clicking it is
refused server-side — `NDA_DISPOSITION_NEXT_STAGE` has no `'Signed'` key — so this is a cosmetic/UX
residual, not a data-integrity risk. This exact residual class is already recorded in
`DPEG_Disposition_Edit.permissionset-meta.xml` ("A user holding BOTH sets does see it; runbook 1.6
and gate G7 own that residual.") — Item 1 adds one more NDA state where it can be observed, not a new
class of issue.

### Deferred, explicitly out of scope for this change

| Item | Status |
|---|---|
| Data cleanup of Acquisition NDAs currently parked on `Status = 'Sent'` under the pre-2026-08-16 meaning | Explicitly deferred by the brief as a separate data-remediation item — no records were touched by this change. |
| LOI Offer Price / Offer Cap Rate percentage-entry bug | Under **separate, live investigation** — not part of this change and not touched by either item documented here. |
| Reconsidering `LOI_Signed_Notify`'s scope/gating before reactivation | Deliberately left as an open decision for whoever reactivates the flow — see *Reactivation* above. |

### Dependencies

- Item 2 depends on the 2026-08-16 Acquisition LOI stage-sequence design (`Stage__c` ending at
  `'Signed'`) being current — if that sequence changes again, `LOI_Signed_Status_Sync`'s
  `Is_Signed` decision would need to be re-pointed at whatever terminal value replaces `'Signed'`.
- `LOI_Signed_Notify`'s future reactivation depends on `LOI_Signed_Status_Sync` continuing to be the
  only writer of `LOI_Signed__c` for Acquisition LOIs — if a second automation ever also sets that
  checkbox, the notify flow's entry filter and this doc's data-flow diagram would both need review.

---

## ARCHITECTURE.md Update

**No edit was made to `ARCHITECTURE.md`.** Neither item touches any of ARCHITECTURE.md § 6's stated
triggers for a mandatory update (no custom object added, no new Apex service introduced, no
integration boundary touched) — both are single-object declarative changes to metadata (a FlexiPage
visibility rule, a new before-save Flow, and one existing Flow's activation state). `LOI__c` and
`NDA__c` are pre-existing objects and no Apex was created or modified.

---

## 📜 Change History

| Date | Author | Change Description |
|------|--------|--------------------|
| 2026-08-18 | Documentation Agent | Initial creation, documenting the NDA Advance Stage FlexiPage fix (Item 1) and the new `LOI_Signed_Status_Sync` flow plus the deliberate pause of `LOI_Signed_Notify` (Item 2), both completed and deployed to `usman-dpeg` prior to this pass. |
