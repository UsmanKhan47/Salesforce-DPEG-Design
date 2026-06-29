# Disposition Closing Checklist — Design

**Date:** 2026-06-24
**Status:** Approved

## Goal
A small checklist LWC on the Disposition record page, directly under the wire-fraud card
(`wireVerification`), showing three checkbox tasks — **PSA Executed**, **Title Company Engaged**,
**Closing Statement Received** — built the same way as the transaction tasks (real Task records,
checked off via Apex). Native Salesforce/SLDS styling. Visible in the Closing stage only.

## Data model — standard `Task` records (no new object/fields)
Three Tasks hang off the Disposition via `Task.WhatId` (Disposition__c has Activities enabled),
reusing the existing Task custom fields created for the transaction tasks:
- `Task_Group__c = 'Disposition Closing'` — marker used to find/scope these tasks
- `Task_Sequence__c` = 1 / 2 / 3 — order
- `Subject` = `PSA Executed` | `Title Company Engaged` | `Closing Statement Received`
- Completion = standard `Status` field; `done` is read from `IsClosed`.

## Apex — `DispositionTaskController` (mirrors `TransactionTaskController`)
- `getClosingTasks(Id dispositionId) : List<ClosingTask>` — **find-or-create**. Queries the 3 Tasks
  by `WhatId` + `Task_Group__c`; inserts any missing from the template; returns them ordered by
  sequence. Not `cacheable` (it performs the create), so the LWC calls it imperatively. This makes
  every disposition self-seed on first view — no seed script or trigger needed.
- `setTaskDone(Id taskId, Boolean done) : void` — sets `Status` to `Completed` (done) or an open
  status (re-open). Toggle, not lock.
- DTO `ClosingTask { id, subject, sequence, done, completedDate }`.

## LWC — `dispositionClosingTasks`
- `@api recordId`; loads tasks imperatively in `connectedCallback`; re-loads after each toggle.
- SLDS card "Closing Checklist" with an *N/3 complete* badge, styled to match the sibling
  `wireVerification` card.
- Three rows, each a native `lightning-input type="checkbox"` + label; completed rows show a done
  state (strike-through + completed date). Checkbox change → `setTaskDone` → reload.

## Placement
`dispositionMain.html`, inside `<template if:true={isClosing}>`, immediately after
`<c-wire-verification>`.

## Perms & tests
- Add `DispositionTaskController` class access to the disposition permission set (same one granting
  the other disposition controllers).
- `DispositionTaskControllerTest`: create a Disposition → `getClosingTasks` creates 3 → `setTaskDone`
  one → re-query asserts done/sequence/idempotent create (calling twice doesn't duplicate).

## Out of scope (YAGNI)
No confirm dialogs, no wire-style verification modal, no phases/groups — three toggling checkboxes.
