---
name: activity-panel-layout-coupling
description: A flexipage activityPanel and its object's layout platformActionList must deploy as one unit — splitting them ships an Activity panel with no composer buttons
metadata:
  type: feedback
---

When a change set adds `runtime_sales_activities:activityPanel` to a flexipage, the same object's `*.layout-meta.xml` (carrying `LogACall` / `NewEvent` / `NewTask` in `platformActionList`) must ship in the **same deploy**. Never split them across deploys, and never let a partial-selection choice at Gate 3 separate them.

**Why:** the Activity tab's composer buttons come from the layout's `platformActionList`, not from the flexipage and not from `quickActionList`. Flexipage-without-layout renders an Activity panel with zero composer actions — a visibly broken feature. This exact bug already shipped on Opportunity, Lead, Transaction and Disposition in this project, so it is a repeat failure mode, not a hypothetical.

**How to apply:** at the Gate 3 component list, mark such pairs as an atomic unit. If the user picks `[P] partial` and selects one without the other, stop and flag the coupling instead of deploying the selection as given.
