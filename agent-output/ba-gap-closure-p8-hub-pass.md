# P8 HUB PASS — consolidated permission-set input (BA Gap Closure, WS1–WS8)

**Date:** 2026-08-30
**Branch:** `qa/lifecycle-simulation-2026-08-27`

⚠ **Why this file exists.** The parent design doc (`agent-output/design-requirements.md`,
"BA Acceptance-Criteria Gap Closure (8 Workstreams)") was **overwritten in the shared working tree
by a concurrent session** writing an unrelated design ("Acquisitions Gap-Fix, Items 1–6"). It was
never committed and is not recoverable. Every entry below is transcribed from the **completion
report of the agent that built the field**, which is stronger evidence than the design doc's
predictions: each was measured against `usman-dpeg`, not forecast.

🔴 **This pass is a GATE, not cleanup.** Two independent measurements today proved that a deployed
but ungranted field does not degrade a feature — it aborts the DML statement and takes down
unrelated work. See "Why this is a gate" below.

---

## 1. The grant matrix

| Object.Field | WS | Permission set | Access | Notes |
|---|---|---|---|---|
| `Inbound_Email_Staging__c.Received_DateTime__c` | WS1 | `Broker_Protection_Access` | read | 🔴 **MANDATORY, same deploy or earlier.** `InboundEmailStagingSelector.selectById` is `WITH USER_MODE` and is the first thing every inbound email does. Currently causing **~105 test failures**. |
| `Lead.Field_Confidence_JSON__c` | WS7 | `DPEG_Acquisition_Edit` | **read + EDIT** | 🔴 Measured mandatory. Read-only silently disables the feature with nothing logged. |
| | | `DPEG_Acquisition_View`, `DPEG_Principal_PSG` | read | |
| | | `DPEG_Junior_Analyst_PSG` | read + edit | Matches sibling pattern. |
| `Lead.Low_Confidence_Field_Count__c` | WS7 | `DPEG_Acquisition_Edit` | **read + EDIT** | 🔴 Also the Review Queue's filter field — unreadable ⇒ that list view returns nothing, forever. |
| | | `DPEG_Acquisition_View`, `DPEG_Principal_PSG` | read | |
| | | `DPEG_Junior_Analyst_PSG` | read + edit | |
| | | `DPEG_Admin_Access` | read | Filter field; see WS6. |
| `Lead.Broker__c` | WS8 | `DPEG_Acquisition_Edit` | **read + EDIT** | 🔴 Written by intake. Missing Edit is pipeline-level, not cosmetic. |
| | | `Broker_Protection_Access` | read + edit | Recommended — broker identity is squarely this set's domain. |
| `Lead.Broker_Firm__c` | WS8 | as `Broker__c` | | |
| `Lead.Deal_Name__c` | WS6 | `Broker_Protection_Access`, `DPEG_Acquisition_View`, `DPEG_Acquisition_Edit`, `DPEG_Admin_Access` | read | Formula. Now a column on all five list views. |
| `Property__c.Normalized_Address__c` | WS3 | `DPEG_Acquisition_Edit` | **read + EDITABLE** | 🔴 See §3 — the backfill is hard-blocked without Edit. |
| | | `DPEG_Acquisition_View`, `DPEG_Property_View` | read | |
| `Opportunity.DPEG_First__c` | WS2 | `DPEG_Acquisition_View` | read | |
| | | `DPEG_Acquisition_Edit` | read + write | |
| `Opportunity.BP_Expiry__c` | WS2 | `DPEG_Acquisition_View`, `DPEG_Acquisition_Edit`, `DPEG_Opportunity_View` | read | Formula. |
| `Opportunity.Days_in_System__c` | WS2 | as `BP_Expiry__c` | read | Formula. |
| `Opportunity.Broker_First_Seen__c` | WS2 | — | **no delta** | Same field, type change only. Already granted on all three sets. |
| `Lead.BP_Expiry__c` | WS5 | — | **no delta** | Formula body changed only. |
| `Broker_Protection_Config__mdt` (8 fields) | WS5 | — | **none needed** | Verified by mechanism: `getInstance()` is plain sObject access (no FLS check), type is `visibility=Public`, and `$CustomMetadata` in a formula evaluates in system context. Optional: `customMetadataTypeAccesses` on an admin set if someone should edit the record in **Setup** — that is an edit-in-Setup permission, not a runtime read. |
| Turnstile (WS4) | WS4 | — | **none** | Adds no field. Its two grants live in its own new `Turnstile_Integration_Access` set, matching the `SharePoint_Integration_Access` precedent. |

### 🔴 Two conflicts between reports — the MEASURED answer wins

1. **`Lead.Field_Confidence_JSON__c` / `Low_Confidence_Field_Count__c`.** The WS6 admin agent
   declared these read-only ("machine-written"). The WS7 developer agent then **measured** that
   read-only breaks the write. **Use read + EDIT on `DPEG_Acquisition_Edit`.**
2. **`Property__c.Normalized_Address__c`.** The admin agent declared it read-only
   ("system-stamped, do not edit directly"). WS3 measured that the backfill cannot run without
   Edit. **Use read + editable on `DPEG_Acquisition_Edit`.**

---

## 2. Why this is a gate, not cleanup — measured twice today, on two objects

"Apex DML runs in system mode by default" is **false** for a field with **zero `FieldPermissions`
rows**. Such a field is not *denied*; it is **absent from the schema** for that principal, so the
whole statement is refused.

| Object | What happened |
|---|---|
| **Lead** (WS7) | Fields deployed and written but ungranted ⇒ `System.DmlException: Operation failed due to fields being inaccessible on Sobject Lead`. **42 of 45 tests failed, 38 unrelated.** Isolated three ways: not deployed → 39/39 pass; deployed but not written → 39/39 pass; deployed **and** written → red. |
| **Opportunity** (WS2/WS3) | Adding `o.DPEG_First__c` to an existing `update updates;` broke lead conversion **org-wide** — `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY ... There was an error converting the lead`. **28 of 30 tests red, including every pre-existing one.** |

Two guards were added so the deploy-vs-grant window costs a feature rather than the pipeline:
`EmailToLeadService.applyFieldConfidence` uses a cached `isCreateable()` guard, and
`LeadConvertService` now states `Database.update(updates, true, AccessLevel.SYSTEM_MODE)`.
**An FLS grant alone is the weakest fix** — it only helps personas holding that set, and the
deploy-time test-runner admin typically holds none.

---

## 3. Pre-existing gap the pass should decide on (NOT caused by this work)

Measured by query: `Broker_Protection_Access` and `DPEG_Admin_Access` hold **zero**
`FieldPermissions` rows for `Lead.Parse_Confidence__c`, `Lead.Deal_Notes__c` and
`Lead.First_Seen_Date__c`. They are not *partially* behind on the Broker-Protection Lead fields —
they are absent from them. Those columns render blank for those personas **today**, independent of
this change.

**Recommendation (a decision for the pass, not an agent's to take):** backfill those three on
`Broker_Protection_Access` in the same pass. A permission set named for this feature that cannot
read the feature's own fields is a trap for the next person.

---

## 4. Carried-over fixes to land with this pass

1. **Two WS2 tests read `DPEG_First__c` with plain SOQL** and hit `No such column` at runtime —
   `LeadConvertServiceTest.aLeadWithNoDpegFirstLeavesTheOpportunityLookupBlank` (~line 565) and
   `assertBulkOpportunitiesAndProperties` (~line 1824). Both need `WITH SYSTEM_MODE`.
2. **`scripts/load-broker-protection-config.apex`** carries a stale seed-length assertion
   (`expect 19254`); WS7's prompt edit took it to **20,592**. (Assigned to the WS8 developer.)
3. **The Broker column on the five new list views** currently points at `Broker_First__c`, which
   `EmailToLeadService` never wrote — blank for the primary channel. (Assigned to the WS8 developer:
   populate it from `request.brokerCompany` when non-blank.)

---

## 5. The backfill's own preconditions (WS3)

`scripts/backfill-property-normalized-address.apex` — 61 rows today, all with an address,
normalising to **61 distinct keys, zero collisions**. It is idempotent and re-runnable.

🔴 It is **hard-blocked** until this pass lands, for two reasons that no code change can work around:
- **Anonymous Apex cannot use `SYSTEM_MODE` at all**, so `editable=true` on
  `Property__c.Normalized_Address__c` is the only route.
- `Property__c` OWD is **Private**, so the runner also needs Modify All Data.

Both are recorded in the script header as run-as preconditions.

---

## 6. Deploy order (measured, not assumed)

```
1. Broker_Protection_Config__mdt (type + 8 fields) + Apex
      accessors all default, so the org behaves exactly as pre-WS5 in this window
2. RUN scripts/load-broker-protection-config.apex
      🔴 MUST be re-run after WS7's prompt edit, or the org keeps sending the
         19,254-char prompt, returns no field_confidence, and stamps 0 on every
         Lead — silently absent, nothing logged
      verify: SELECT DeveloperName, Protection_Window_Days__c FROM Broker_Protection_Config__mdt
3. Opportunity fields (incl. Date→DateTime) + validation rule
4. PERMISSION SETS  ← this pass. HARD GATE.
5. Remaining Apex + the five list views
6. RUN scripts/backfill-property-normalized-address.apex   (needs step 4)
```

The two `BP_Expiry__c` formula fields **cannot validate before step 2**. They fail with
`Field Default does not exist. Check spelling.` — an error that names the **record**, not the
syntax. Do not misread it as `$CustomMetadata` being unsupported; it is supported at API 67 in this
org and was proven both ways (deploy `0Afiw000000Tj09CAC` failed pre-record,
`0Afiw000000Tj1lCAC` succeeded post-record).

---

## 7. Standing constraint for whoever runs this pass

🔴 A `PermissionSet` deploy **REPLACES that file's entire `fieldPermissions` set.** That is why no
build stream was allowed to touch one, and why this is a single consolidated edit. Read each target
set's current content and merge — never author a set from the table above alone.

⚠ Concurrent sessions share this working tree. Diff every hub file against `HEAD` before deploying,
and re-read it immediately before the deploy.
