# LWC Code Review — Part 1 (First 42 bundles)

**Reviewer:** salesforce-code-review subagent
**Date:** 2026-07-21
**Scope:** 42 LWC bundles (first half). `.js` / `.html` / `.css` / `.js-meta.xml` only. Jest `__tests__`, Apex, and metadata are out of scope for this pass.
**Reference:** ARCHITECTURE.md §5 (LWC/UI Architecture), `.claude/rules/`.

Bundles reviewed: activeTransactionsList, advanceDealStage, backupBrokers, bovComparisonMatrix, bovOutreach, brokerAssignmentActions, brokerAssignmentDetail, brokerAssignmentHistory, brokerAssignmentKpis, brokerAssignmentList, brokerAssignmentNotes, brokerCheckInAlerts, brokerDealIntakeForm, brokerFirmCard, brokerListing, brokerListingActivity, brokerPortfolioStatus, brokerReplaceQuickAction, brokerScorecard, brokerStats, brokerTotals, brokersList, dealDocStatus, dealMessageLog, dealSendToConstructionReview, dealSendToDevelopmentReview, dispositionClosing, dispositionClosingTasks, dispositionMain, dispositionOffer, dispositionSidebar, leadChannels, leaseAttention, leaseInquiryKpis, leaseInquiryList, leaseNegotiationLog, leasePipelineByStage, leaseStatusSummary, listDatatable, listingAlerts, loiCounterOffer, onboardingCardChild.

---

## Summary

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | 5 (across 3 bundles) |
| 🟡 WARNING | ~35 (2 discrete + 2 cross-cutting patterns) |
| 🟢 SUGGESTION | 2 |

**apiVersion:** All in-scope bundles are 67.0. `leaseNegotiationLog` is 62.0 — this is the documented deliberate exception (ARCHITECTURE §5), NOT flagged.

---

## 🔴 CRITICAL — imperative Apex with NO error handling

These are imperative, **mutating** Apex calls (DML) whose failure is completely silent to the user — no toast, no inline message. On failure the promise rejects unhandled; the UI shows a "success-looking" state (modal stays open with no reason, or a checkbox toggles visually but the change is never persisted). Violates ARCHITECTURE §5 "Error Handling" (catch → user-safe toast).

### 1. brokerAssignmentActions/brokerAssignmentActions.js:42-51 — `logCheckIn`
```js
async handleLogCheckIn() {
    if (this._saving) return;
    this._saving = true;
    try {
        await logCheckIn({ assignmentId: this.recordId });
        await this.refresh();
    } finally {                       // <-- try/FINALLY, no CATCH
        this._saving = false;
    }
}
```
`try/finally` with no `catch`. If `logCheckIn` throws, the error is unhandled and the user gets no feedback. HTML (`brokerAssignmentActions.html`) has no inline error region either.
**Fix:** add a `catch` that dispatches a `ShowToastEvent` (error variant) with `error.body.message`.

### 2. brokerAssignmentActions/brokerAssignmentActions.js:58-72 — `replaceBroker`
Same `try/finally`-no-`catch` pattern. A failed broker replacement leaves the modal open with no explanation.
**Fix:** add `catch` → error toast (mirror the correct pattern already used in `brokerReplaceQuickAction.js`).

### 3. brokerAssignmentDetail/brokerAssignmentDetail.js:152-161 — `logCheckIn`
Identical `try/finally`-no-`catch`. No user feedback on failure.
**Fix:** add `catch` → error toast.

### 4. brokerAssignmentDetail/brokerAssignmentDetail.js:169-184 — `replaceBroker`
Identical `try/finally`-no-`catch`.
**Fix:** add `catch` → error toast.

> Note: `brokerReplaceQuickAction.js:51-75` calls the *same* `BrokerAssignmentController.replaceBroker` and handles it correctly (try/catch → `this.error` + success toast). The two components above are inconsistent with the established repo pattern — fix them to match.

### 5. dispositionClosingTasks/dispositionClosingTasks.js:49-53 — `setTaskDone`
```js
handleToggle(event) {
    const taskId = event.target.dataset.id;
    const done = event.target.checked;
    setTaskDone({ taskId, done }).then(() => this.load());   // <-- NO .catch()
}
```
A **mutating** Apex call (writes Task completion) with no `.catch()`. If it fails, the checkbox shows toggled but the DB is unchanged and the user is never told. Data-integrity risk.
**Fix:** add `.catch(e => …ShowToastEvent error…)` and revert/reload the checkbox state.

---

## 🟡 WARNING

### W1. dispositionClosingTasks/dispositionClosingTasks.js:15-19 — silent swallow on read
```js
load() {
    return getClosingTasks({ dispositionId: this.recordId })
        .then((data) => { this._tasks = data || []; })
        .catch(() => { this._tasks = []; });   // <-- swallows error, no user feedback
}
```
The `catch` sets an empty list and shows nothing — on a genuine failure the checklist looks *legitimately empty* (misleading) rather than errored. Violates §5. **Fix:** surface an error toast / error state instead of masquerading as empty.

### W2. brokerListing/brokerListing.js:28-30 — `console.log` + dead stub wired to a live button
```js
handleReplaceBroker() {
    console.log('Replace Broker — stub');
}
```
`console.log` left in production code, and `handleReplaceBroker` is a no-op stub bound to a visible "Replace Broker" button (dead/incomplete feature — the button does nothing). **Fix:** remove the `console.log`; either wire the button to the real action (`brokerReplaceQuickAction`) or remove/disable it.

### W3 (cross-cutting). `@wire` handlers read `data` but never handle `error` → blank/broken UI on failure
Per §5, a wire that ignores `error` leaves the tile/list/card blank with no explanation when the Apex/LDS call fails. This is the dominant pattern in this half — nearly every read component does it. Notable instances (bundle — line of the wired handler):

| Bundle | Line | Adapter |
|--------|------|---------|
| activeTransactionsList | 51 | getActiveTransactions (Apex) |
| backupBrokers | 9 | getSubmissions |
| bovComparisonMatrix | 36 | getSubmissions |
| bovOutreach | 13 | getOutreachSummary |
| brokerAssignmentActions | 18, 25 | getDetail, getBrokerOptions |
| brokerAssignmentDetail | 34, 41 | getDetail, getBrokerOptions |
| brokerAssignmentHistory | 12 | getDetail |
| brokerAssignmentKpis | 6 | getKpis |
| brokerAssignmentList | 40 | getAssignments |
| brokerAssignmentNotes | 16 | getNotes |
| brokerCheckInAlerts | 11 | getAlerts |
| brokerFirmCard | 10 | getBrokerFirm |
| brokerListing | 10 | getListing |
| brokerListingActivity | 20 | getRecord (LDS) |
| brokerPortfolioStatus | 13 | getPortfolio |
| brokerReplaceQuickAction | 27, 29 | getRecord (LDS), getBrokerOptions |
| brokerStats | 15 | getBrokerHub |
| brokerTotals | 6 | getBrokerTotals |
| brokersList | 41 | getBrokerHub |
| dealDocStatus | 51 | getDocStatus |
| dealMessageLog | 55 | getMessages |
| dispositionClosing | 8 | getClosingSummary |
| dispositionMain | 9 | getRecord (LDS) |
| dispositionOffer | 11 | getRelatedListRecords (LDS) |
| dispositionSidebar | 9 | getRecord (LDS) |
| leadChannels | 14 | getFunnel |
| leaseAttention | 10 | getAttention |
| leaseInquiryKpis | 7 | getHomeKpis |
| leaseInquiryList | 33 | getRecentInquiries |
| leaseNegotiationLog | 25 | getLog |
| leasePipelineByStage | 19 | getPipelineByStage |
| leaseStatusSummary | 14 | getLeaseSummary |
| loiCounterOffer | 126, 134 | getRecord (LDS), getCounterOffers |

**Fix:** destructure `error` and render a small error/empty state (a shared helper would cover most). LDS `getRecord` wires are lower-risk (error rare) but still leave a blank card. `brokerScorecard.js` and `brokerDealIntakeForm.js` are the only two read components that capture the wire `error` — use them as the template (though see S1).

### W4 (cross-cutting). SLDS 2 — hardcoded colors (bare hex / rgba), no design token
§5 Styling requires design tokens (`--slds-g-*`), not hardcoded colors. Two forms of this debt are present across nearly all in-scope bundles:

**(a) Inline style-strings built in `.js`** with bare hex and zero token fallback — pill/badge/bar/donut/icon color builders. Worst offenders:
`activeTransactionsList.js` (STAGE/RISK/FALLBACK/pillWrap/pillDot/tasksBar, ~lines 9-44,94), `bovComparisonMatrix.js` (6-9,78-79), `brokerAssignmentDetail.js` (STATUS_META + flag colors + pillWrap/pillDot, 10-19,55-57,87,106,138-139), `brokerAssignmentList.js` (6-12,27,46-48,65-80), `brokerAssignmentKpis.js` (iconColor 10-12), `brokerCheckInAlerts.js` (TILES 4-7,16), `brokerListing.js` (iconColor 19-22), `brokerListingActivity.js` (`iconVar` + `_healthColor` assign bare hex to `--slds-c-*` tokens, 14,30-48), `brokerPortfolioStatus.js` (SEG 4-8,22-23), `brokerScorecard.js` (BARS 5-9,35), `brokerStats.js` (CARD_META 5-10), `brokersList.js` (STATUS/pillWrap/pillDot 6-12,83-84), `dispositionClosing.js` (iconColor 19-22), `dispositionClosingTasks.js` (badgeStyle 44-46), `leadChannels.js` (META 5-9,40), `leaseAttention.js` (pill/dot 4-19), `leaseInquiryKpis.js` (iconColor 12-15), `leaseInquiryList.js` (STAGE_ACCENT/BALL/pill 5-17,54-61,71), `leasePipelineByStage.js` (ACCENT 4-12,41-42), `loiCounterOffer.js` (DIRECTION/pillWrap/pillDot 12-17,182-183).

**(b) Bare hex / rgba in `.css` accent & status colors.** Structural properties correctly use the P9 `var(--slds-g-*, #fallback)` pattern (acceptable), but semantic/status colors remain bare. Examples: `dealDocStatus.css` (`.doc-name--muted #16325c`, `.doc-meta #5a6b7b`, `.divider #f0f2f5`, all `.pill--* `bg/fg/shadow, `.doc-icon--nda rgba(...)`), `brokerAssignmentNotes.css` (`#1A3464`, `#FBFAF9`, `#EFEDE9`, `#3E3B37`), `onboardingCardChild.css` (`.stat-card--done #ebf7ee/#b5e3c1`), and similarly across `brokerAssignmentDetail.css`, `brokerScorecard.css`, `leaseNegotiationLog.css`, `leaseInquiryList.css`, `dealMessageLog.css`, etc.

**Fix:** move accent/status palettes to `--slds-g-color-*` tokens (or at minimum the `var(--token, #fallback)` P9 form). This is pre-existing UI debt, not a functional defect — recommend a dedicated SLDS-token sweep rather than blocking this pass on it.

---

## 🟢 SUGGESTION

### S1. brokerScorecard — wire `error` captured but never rendered
`brokerScorecard.js:15-22` correctly assigns `this.error = error`, but `brokerScorecard.html` only branches on `hasCards`; on error it falls through to the "No broker scorecard data available." empty state (misleading — looks like no data rather than a failure). Consider a distinct error state. (Still better than the W3 components, which don't capture `error` at all.)

### S2. Data-access priority (§5)
Several list/summary components use imperative Apex (aggregates / cross-object joins / server-derived parent) where LDS can't express the query — this is the sanctioned fallback and is fine. No change required; noting for completeness. `dispositionMain`, `dispositionSidebar`, `dispositionOffer`, `loiCounterOffer`, `brokerListingActivity` already use LDS (`getRecord` / `getRelatedListRecords`) — good.

---

## Good practices observed

- `advanceDealStage`, `dealSendToConstructionReview`, `dealSendToDevelopmentReview` — headless quick actions with clean try/catch → success + error toasts. Exemplary.
- `brokerReplaceQuickAction`, `loiCounterOffer`, `dealMessageLog`, `leaseNegotiationLog`, `brokerAssignmentNotes`, `brokerDealIntakeForm` — imperative *mutations* all correctly surface errors (toast or inline). `leaseNegotiationLog.save()` is particularly careful to isolate a post-commit refresh failure from a genuine save failure.
- `onboardingCardChild`, `listDatatable`, `listingAlerts` — correct presentational split (no Apex; props in / events out). `onboardingCardChild` receives its icon color as an `@api` prop (color lives in the parent) — acceptable.
- `brokerDealIntakeForm` — guest portal form handles both the wire `error` and the imperative `submitDeal` `.catch`, with a honeypot field; solid.
- `brokerAssignmentActions.html` / `brokerReplaceQuickAction` modals use `role="dialog"` + `aria-modal` + `aria-label` — good accessibility.

---

## Verdict (this scope)

**CHANGES REQUIRED** — 5 critical no-error-handling issues on mutating Apex calls across 3 bundles (`brokerAssignmentActions`, `brokerAssignmentDetail`, `dispositionClosingTasks`) must be fixed before deployment. The W3 (wire error handling) and W4 (SLDS hardcoded colors) patterns are pervasive but non-blocking debt; recommend addressing W3 broadly and scheduling W4 as a token sweep.
