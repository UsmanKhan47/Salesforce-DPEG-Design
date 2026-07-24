# LWC Code Review — Part 2 (second-half, 41 bundles)

**Reviewer:** salesforce-code-review subagent
**Date:** 2026-07-21
**Scope:** 41 LWC bundles (`.js`, `.html`, `.css`, `.js-meta.xml`) under `force-app/main/default/lwc/`. Apex, Jest `__tests__`, and metadata explicitly out of scope. Reviewed against `ARCHITECTURE.md` §5 (LWC/UI) and `.claude/rules/`.

Bundles reviewed: onboardingChecklist, onboardingChecklistProgress, onboardingKpis, onboardingPortfolioProgress, onboardingPropertyList, onboardingRiskAlerts, onboardingTaskProgressByCategory, onboardingTimeSla, opportunityPipeline, pipelineStageBoard, psaVersionLog, recentLeads, recentOpportunities, renewalAttention, renewalKpis, renewalList, renewalTimeline, rentRoll, sellMeterHeader, sellMeterLegend, sellMeterList, sellMeterStats, statCard, submitForApproval, topBrokers, totalLeads, totalOpportunities, transactionChecklistSummary, transactionCriticalDates, transactionKpis, transactionPhaseCards, transactionStageDonut, transactionTaskCards, transactionTaskGroups, utils, wireVerification, workOrderEscalations, workOrderKpis, workOrderList, workOrderTimeline, workOrderUntouched.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| WARNING  | 3 (one systemic) |
| SUGGESTION | 3 |
| PASSED checks | apiVersion (all 67.0), no hardcoded record Ids, presentational/feature split, accessibility, no TODO/FIXME, no console.log except one eslint-disabled |

**Verdict for this scope: CHANGES REQUIRED** — three mutating imperative Apex calls have no error handling and fail silently, one of them on an anti-fraud wire-verification save.

---

## CRITICAL

### C1 — `transactionTaskGroups` — `completeTask` has no error handling (silent write failure)
- **File:** `transactionTaskGroups/transactionTaskGroups.js`, lines 237–242 (`confirmComplete()`).
- **Code:**
  ```js
  async confirmComplete() {
      const { taskId, notes } = this._confirm;
      this._confirm = {};
      await completeTask({ taskId, notes });
      await refreshApex(this._wire);
  }
  ```
- **Rule violated:** ARCHITECTURE §5 "Apex methods throw `AuraHandledException`… LWC catches, displays user-safe message via toast." Review checklist: "Error Handling — Try-catch around imperative Apex calls."
- **Problem:** No `try/catch`, no `.catch`, no toast. If `completeTask` rejects, the promise is unhandled, the checkbox was already reset to unchecked in `handleCheck` (line 217), and the confirm modal was already closed (line 239) — so the user sees the task revert with **no error message** and believes nothing happened. Silent loss of a user action.
- **Fix:** Wrap in `try/catch`; on failure, surface `e.body.message` via `ShowToastEvent` (the component doesn't import `ShowToastEvent` — it must be added, as done in `submitWire`). Consider not clearing `_confirm` until the call succeeds.

### C2 — `wireVerification` — `saveWire` has no `.catch` (silent failure of an anti-fraud control)
- **File:** `wireVerification/wireVerification.js`, lines 58–71 (`handleSave()`).
- **Code:**
  ```js
  handleSave() {
      this.isSaving = true;
      saveWire({ ... })
          .then(() => refreshApex(this._wired))
          .finally(() => { this.isSaving = false; });
  }
  ```
- **Rule violated:** ARCHITECTURE §5 error-handling boundary; review checklist "Error Handling."
- **Problem:** `.then().finally()` with **no `.catch`**. If `saveWire` rejects, the spinner clears (via `finally`) but no error is shown; the user assumes the wire verification saved when it did not. This is the anti-fraud wire-instructions verification (DPEG brief Section 06) — silent failure here is a control gap, not just a UX nit. No `ShowToastEvent` import at all.
- **Fix:** Add `.catch(e => this.dispatchEvent(new ShowToastEvent({ title: 'Could not save the wire verification', message: (e && e.body && e.body.message) || 'Unexpected error', variant: 'error', mode: 'sticky' })))`.

### C3 — `onboardingChecklist` — `completeTask` in `try/finally` with no `catch`
- **File:** `onboardingChecklist/onboardingChecklist.js`, lines 99–110 (`confirmComplete()`).
- **Code:**
  ```js
  async confirmComplete() {
      const { taskId, notes } = this._confirm;
      this._saving = true;
      try {
          await completeTask({ taskId, notes: (notes || '').trim() });
          this._confirm = {};
          await refreshApex(this._wire);
          notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
      } finally {
          this._saving = false;
      }
  }
  ```
- **Rule violated:** ARCHITECTURE §5 error-handling boundary; review checklist "Error Handling."
- **Problem:** `try/finally` with **no `catch`**. On failure the spinner clears, but no toast is shown and the confirm modal stays open (line 104 `this._confirm = {}` is never reached on error) with the checkbox reset — an unhandled rejection with no user-safe message. No `ShowToastEvent` import.
- **Fix:** Add a `catch` that dispatches an error toast with `e.body.message`.

---

## WARNING

### W1 — `transactionTaskGroups` wire handler ignores `result.error` (confirmed — silent empty state)
- **File:** `transactionTaskGroups/transactionTaskGroups.js`, lines 37–43.
- **Code:**
  ```js
  @wire(getTaskGroups, { transactionId: '$recordId' })
  wired(result) {
      this._wire = result;
      if (result.data) {
          this._data = result.data;
      }
  }
  ```
- **Rule violated:** ARCHITECTURE §5 review checklist "Wire Error Handling — Error property handled in wire."
- **Problem (CONFIRMED — this was the flagged suspect):** The handler consumes `result.data` but never inspects `result.error`. On an Apex error, `_data` stays `[]`, `isEmpty` (line 45) returns `true`, and the component silently renders the empty state instead of an error — indistinguishable from a transaction that genuinely has no tasks. This is the exact failure mode behind the "transaction tasks empty" class of defects and is worse here than on a read-only tile because the component is interactive.
- **Fix:** Add an `else if (result.error)` branch that captures the error and renders a distinct error state (see `rentRoll.js` lines 30–45 for the correct pattern in this same codebase).

### W2 — Systemic: read-only wire components consume `data` but ignore `error` (blank UI on failure)
- **Rule violated:** ARCHITECTURE §5 "Wire Error Handling."
- **Problem:** ~30 components use the shorthand `@wire(getX) wired({ data }) { if (data) this._x = data; }` (or the multi-line equivalent) with **no `error` branch**. On Apex/network failure they render a blank/empty state with no message and no diagnostics. `rentRoll.js` is the **only** component in this scope that does it correctly (handles `{ data, error }`, exposes `errorMessage`, renders an error card).
- **Affected bundles:** onboardingKpis, onboardingChecklistProgress, onboardingPortfolioProgress, onboardingPropertyList, onboardingRiskAlerts, onboardingTaskProgressByCategory, onboardingTimeSla, opportunityPipeline, pipelineStageBoard, recentLeads, recentOpportunities, renewalAttention, renewalKpis, renewalList, sellMeterHeader, sellMeterList, sellMeterStats, topBrokers, totalLeads, totalOpportunities, transactionChecklistSummary, transactionCriticalDates, transactionKpis, transactionPhaseCards, transactionStageDonut, transactionTaskCards, workOrderEscalations, workOrderKpis, workOrderList, workOrderTimeline, workOrderUntouched, psaVersionLog (`wiredOpp`, `wiredVersions`). (transactionTaskGroups covered separately in W1.)
- **Note:** For pure read-only KPI/list tiles a silent blank is lower-impact than for interactive components, but it is still a standards deviation and hides platform errors during UAT. Recommend adopting the `rentRoll` pattern as the house standard.
- **Fix:** Add an `error` branch to each wire handler and a minimal error state in the template.

### W3 — SLDS 2: hardcoded colors (bare hex/rgb with no design token)
- **Rule violated:** ARCHITECTURE §5 Styling — "Use design tokens (`--slds-g-*`), not hardcoded colours/spacing."
- **Note on acceptable pattern:** `var(--slds-g-…, #fallback)` (the P9 token-with-fallback pattern) is used heavily and is **acceptable** — not flagged. The finding is **bare hex/rgb with no token wrapper**.
- **Bare-hex in CSS (representative, not exhaustive):**
  - `rentRoll/rentRoll.css` — many: `#3fae5e`, `#c98a33`, `#e0556b`, `#1565c0`, `#9c6b1f`, `#014486`, `#444`, `rgba(201,138,51,…)`, `rgba(1,118,211,…)` (lines 12, 22–24, 30–32, 47–56, 66–70, 78, 83–104, 111–114).
  - `renewalTimeline/renewalTimeline.css` — `#1A3464`, `#FDECEC`, `#B01818`, `#F3B0B0`, `#D42B2B`, `#B0AEA8`, `#F3F6FB`, `#D6E0EE`, `#FBF2DA`, `rgba(26,52,100,…)` (lines 8, 19–20, 23, 33–35, 42, 48).
  - `sellMeterLegend/sellMeterLegend.css` — band colors `#f0faf4/#1B7A4B`, `#fffbf0/#B45309`, `#fff5f5/#B91C1C`, `#5a6b7b` (lines 28–55).
  - `onboardingChecklist/onboardingChecklist.css` — `#0176d3`, `#c9def5`, `#f5faff`, `#1565c0`, `#2e7d32`, `#F2F2F2`, `#ecebea`, `#f3f2f2`, `#f8f8f8`, `#f1f2f4` (lines 34–47, 67, 77–90, 159, 183, 191, 213, 217, 223, 241).
  - `onboardingChecklistProgress/onboardingChecklistProgress.css` — `--slds-c-icon-color-background: #e8a200` (27), `background: #ecebea` (38).
  - `onboardingPortfolioProgress/onboardingPortfolioProgress.css` — `background: #ECEBEA` (11).
  - `sellMeterList/sellMeterList.css` — `#f3f2f2` (33), `#514f4d` (40).
  - `sellMeterHeader/sellMeterHeader.css` — `#c5cdd4` (27).
- **Bare-hex built in JS inline-style strings:**
  - `recentLeads/recentLeads.js` lines 6–26 (`STAGE`, `CONF`, `CHANNEL`/`FALLBACK` maps + `pillWrap`/`pillDot` with `#3e3e3e` etc.).
  - `sellMeterList/sellMeterList.js` lines 8–16 (`METER` map + `pillWrap`/`pillDot`).
  - `psaVersionLog/psaVersionLog.js` lines 12–17 (`DIRECTION` map + `pillWrap`/`pillDot`).
  - `renewalTimeline/renewalTimeline.js` lines 8–18 (`METHOD_META` + `badge()`).
  - `transactionTaskGroups/transactionTaskGroups.js` lines 95, 124, 147–148 (bar/ring/badge styles `#2e7d32`, `#0176d3`, `#bf5d0a`, `#1565c0`, `#2BAFAC`).
  - `onboardingChecklist/onboardingChecklist.js` lines 32, 47 (ring/bar styles).
  - `transactionCriticalDates/transactionCriticalDates.js` lines 87, 100 (`color` map + `iconStyle`).
  - `wireVerification/wireVerification.js` lines 38–40 (`progressBadgeStyle` `#e6f4ea`/`#2e7d32`/`#fef3c7`/`#92400e`).
- **Fix:** Migrate to `--slds-g-*` design tokens (or at minimum the `var(hook, #fallback)` pattern already used elsewhere). This is known P9 SLDS-2 debt; batch it into the styling-uplift track rather than per-bundle. Not deployment-blocking on its own.

---

## SUGGESTION

### S1 — `sellMeterList` leftover `console.error`
- **File:** `sellMeterList/sellMeterList.js`, line 177. Inside the `findOrCreate` catch, alongside a proper error toast, and already `// eslint-disable-next-line no-console`. Deliberate, but ARCHITECTURE §5 review checklist lists "No console.log." Low priority; remove or keep as an intentional diagnostic. The catch/toast handling here is otherwise exemplary.

### S2 — `statCard` passes a raw color into token overrides
- **File:** `statCard/statCard.js`, lines 11–15. `iconStyle` injects `this.iconColor` into `--slds-c-icon-color-foreground-default`. The component itself is a clean presentational pass-through; the hardcoded color originates in the parent tiles that pass hex. Fold into the W3 token migration — no change needed in `statCard` itself.

### S3 — Data-access priority (informational, not a violation)
- Most KPI/list components use imperative Apex via a thin controller because the reads are aggregates / cross-object rollups that LDS cannot express — this is compliant with §5's "Imperative Apex only when LDS cannot express the query." `transactionCriticalDates` and `psaVersionLog` correctly use LDS `getRecord` for single-record reads. No action.

---

## Passed / good practices

- **apiVersion:** all 41 `.js-meta.xml` are `67.0` — compliant with §5 uplift. No stragglers.
- **No hardcoded Salesforce record Ids** anywhere in scope.
- **Presentational vs feature split (§5):** presentational components make no Apex calls — `statCard` and `sellMeterLegend` are stateless shells; no violations found.
- **Accessibility:** interactive chips use real `<button>` elements; modals use `role="dialog"`, `aria-modal`, `aria-labelledby`, `tabindex` (onboardingChecklist, transactionTaskGroups). No clickable-div anti-patterns spotted.
- **`rentRoll`** is the reference implementation for wire error handling in this scope (handles `{ data, error }`, `errorMessage` getter, dedicated error card) — hold it up as the house pattern for fixing W1/W2.
- **`c/utils`** shared module is correctly pure/stateless with no Apex; well-documented; byte-compatible extraction rationale is sound. No issues.
- Imperative Apex done right: `sellMeterList.findOrCreate`, `submitForApproval`, `psaVersionLog.saveVersion`, `renewalTimeline.addUpdate` all catch and surface a user-safe message (toast or inline). Use these as templates for C1–C3.

---

## Verdict

**CHANGES REQUIRED.** Fix C1–C3 (missing error handling on mutating imperative Apex, incl. the anti-fraud wire save) before deployment. W1 (transactionTaskGroups silent-empty wire) should be fixed in the same pass. W2 (systemic wire-error handling) and W3 (SLDS-2 hardcoded colors) are standards debt — schedule, not blocking.
