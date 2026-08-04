# DESIGN REQUIREMENTS — `competingBrokerSubmissions` presentation rework

**Request (verbatim):** "we need to make this lwc better, I don't want any horizontal listview."
**Date:** 2026-08-04
**Scope:** presentation only, one LWC bundle. No Apex, no metadata.

---

## 0. PREMISE CORRECTIONS (read before the design)

Two statements in the brief are not what the repo actually contains. Both change the
recommendation, so they lead.

### PC-1 — The region is confirmed: `sidebar`. This is the whole cause.

`Lead_Record_Page.flexipage-meta.xml` line 813 places `competingBrokerSubmissions` as the
**first item of the `sidebar` region** (`<name>sidebar</name>`, line 841) of template
`flexipage:recordHomeWithSubheaderTemplateDesktop` (line 847). That is the right-hand
one-third column — roughly 340–400 CSS px at a typical desktop width, less on a laptop with
the utility bar open.

Five columns (Broker / Forwarded By / Property Address / Submitted / Status), two of which
carry full email addresses and one a full US street address, cannot fit in ~360px. The
`<div class="lv-scroll">` wrapper with `overflow-x: auto` (CSS line 7–9) is not the bug —
it is the **symptom container** that keeps a too-wide table from bursting the region. Remove
the table and the wrapper becomes unnecessary; remove only the wrapper and the layout breaks
worse. The fix must be the layout, not the wrapper.

### PC-2 — `.lv-*` is NOT a house standard this component belongs to. It is a private one-off.

The brief says the `.lv-*` table chrome is "a shared convention every list LWC in this app
follows." Verified against the repo — it is not:

| Class | Bundles using it | Verdict |
| --- | --- | --- |
| `.lv-error` | `competingBrokerSubmissions`, `recentLeads`, `recentOpportunities`, `renewalList` | **Genuinely shared.** Keep verbatim. |
| `.lv-scroll`, `.lv-table`, `.lv-head`, `.lv-th`, `.lv-cell`, `.lv-row`, `.lv-row_winner`, `.lv-name`, `.lv-sub`, `.lv-muted`, `.lv-empty`, `.lv-empty-text`, `.lv-empty-icon` | **`competingBrokerSubmissions` only** | Private to this bundle. Nothing else references them. |

The actual house list pattern is `lightning-card` (icon + `Title (count)`) → **`c-list-datatable`**
(a shared `lightning/datatable` subclass in `lwc/listDatatable/`) → `.lv-error` inline banner →
`view-all-footer` "View All" link. `recentLeads`, `recentOpportunities` and `renewalList` all
follow it. `competingBrokerSubmissions` **never did** — it hand-rolled a `<table>` and invented
the `.lv-table` family for itself.

Two consequences:

1. Moving to tiles is **not** leaving a family. It is retiring a private one-off. The
   "deviation" is much smaller than the brief assumes — see §4.
2. **Adopting the real house standard would not fix the reported defect.**
   `lightning-datatable` renders its own internal horizontal scroller and enforces minimum
   column widths; `wrap-text` softens it but does not remove it. Putting `c-list-datatable`
   in a 360px sidebar reproduces exactly the scrollbar in the screenshot. So "just use the
   house component" is a dead end here, and that is the justification for the deviation.

### Also verified (facts the design relies on)

- CSS is component-local (LWC style scoping) — restyling this bundle affects nothing else. ✅
- One reactive `@wire(getSubmissions, { leadId: '$recordId' })` over an
  `@AuraEnabled(cacheable=true)` controller. No imperative Apex, no DML. ✅
- Row fields available: `Id`, `Broker_Name__c`, `Broker_Email__c`, `Forwarded_By_Email__c`,
  `Property_Address_Raw__c`, `Submitted_DateTime__c`, `Is_Winning_Submission__c` — exactly the
  seven `CompetingBrokerSubmissionSelector.selectByWinningLead` selects. ✅
- Rows arrive **oldest-first** (`ORDER BY Submitted_DateTime__c ASC`). The winner is normally
  row 1. **Preserve this order — do not re-sort client-side.** The chronological contract is
  documented in the selector's Javadoc.
- No other list LWC sits in a record-page sidebar. `recentLeads` / `recentOpportunities` are in
  `Lead_Funnel` `region2` (`flexipage:appHomeTemplateHeaderTwoColumns`), `renewalList` in
  `Lease_Renewals_Home`, `rentRoll` in the `main` region of `Property_Asset_Record_Page` inside
  a tab. `rentRoll.css` also carries `overflow-x: auto` (`.scroll`, line 36) but it is in a
  full-width tab and a rent roll legitimately has many columns. **Noted, out of scope, not to
  be touched in this change.**

---

## 1. WHAT THE USER REQUESTED

Make the `competingBrokerSubmissions` LWC read better, with **no horizontal list view** — i.e.
nothing in the component may scroll horizontally.

Everything below is either (a) a direct consequence of that, or (b) an explicit
preserve-what-exists requirement from the brief. Nothing new is being added to the feature.

---

## 🔵 ADMIN WORK (salesforce-admin)

**No admin work required for this request.**

No object, field, validation rule, permission set, flow, layout or flexipage change. See §7.

---

## 🟢 DEVELOPMENT WORK (salesforce-developer)

Four files in one bundle: `competingBrokerSubmissions.html`, `.css`, `.js`, and
`__tests__/competingBrokerSubmissions.test.js`. `js-meta.xml` is **unchanged** (stays
`apiVersion` 67.0, `isExposed` true, `lightning__RecordPage`, same `masterLabel`/`description`).

---

## 2. (a) THE LAYOUT — stacked tile per submission

### 2.1 Structure

Replace the `<div class="lv-scroll"><table class="lv-table">…</table></div>` block with an
unordered list of tiles. Everything outside that block (`lightning-card`, title span, error
branch, empty branch) keeps its current shape.

```
lightning-card  (icon-name="standard:lead", slot="title" → "Competing Broker Submissions ({count})")
└── ul.cbs-list            aria-label="Competing broker submissions"
    └── li.cbs-tile  (+ .cbs-tile_winner when Is_Winning_Submission__c)
        ├── div.cbs-tile-head            ← flex, wrap, justify-between
        │   ├── h3.cbs-broker            ← broker NAME (primary)
        │   └── lightning-badge          ← Winner / Competing (unchanged classes)
        ├── lightning-formatted-email.cbs-email   ← broker email (primary-secondary)
        └── dl.cbs-fields                ← labelled secondary facts, stacked
            ├── dt Submitted        / dd lightning-formatted-date-time
            ├── dt Property Address / dd {row.propertyAddress}
            └── dt Forwarded By     / dd lightning-formatted-email | "—"
```

`renewalTimeline` is the closest existing precedent in this repo for a stacked, vertically
reflowing log (its `.rt-entry` / `.rt-content` with `min-width: 0` and `word-break: break-word`).
Mirror its **structure**. ⚠ **Do not copy its CSS values** — `renewalTimeline.css` contains
hardcoded hex colours (`#1A3464`, `#FDECEC`, …) that violate the §5 token rule. The current
`competingBrokerSubmissions.css` is token-clean and must stay that way (see §5).

### 2.2 Visual hierarchy (top to bottom, per tile)

| Rank | Content | Treatment |
| --- | --- | --- |
| **Primary** | Broker name | `<h3>`, `--slds-g-font-weight-7`, `--slds-g-font-scale-base`, `--slds-g-color-neutral-base-10`. Gives each tile an accessible name. |
| **Primary** | Winner / Competing badge | top-right of the tile head, same row as the name, wraps beneath it at extreme narrow widths |
| **Secondary** | Broker email | `lightning-formatted-email`, `--slds-g-font-scale-neg-1`, muted. This is the arbitration key — must stay readable and clickable. |
| **Tertiary** | Submitted date/time | `<dl>` row, label above value |
| **Tertiary** | Property address | `<dl>` row |
| **Quaternary** | Forwarded By | `<dl>` row, last — see §3.2 for the demotion justification |

Reading order matters: the reviewer's question is "**who** claimed this, and **did they win**"
— name + badge answers it in the first line of every tile. Address and forwarder are corroborating
detail, and in the common case (all rows for one property, forwarded by the same coordinator
mailbox — visible in the screenshot: `bestbankaiagent@gmail.com` twice) they are near-constant
across rows, so they belong last.

### 2.3 Winner distinction — three cues, all preserved/carried over

1. **Badge** — `lightning-badge` label `Winner`, class `slds-theme_success` (unchanged JS map).
2. **Left accent stripe** — carry `box-shadow: inset 3px 0 0 var(--slds-g-color-success-base-50, #2e844a)`
   from `.lv-row_winner` onto `.cbs-tile_winner`. Same token, same 3px.
3. **Tinted surface** — carry `background: var(--slds-g-color-surface-container-1, #fafaf9)`.

### 2.4 The no-horizontal-scroll rules (these are the deliverable)

Every one of these is load-bearing. A tile layout still overflows if any is missed.

1. **No `overflow-x` anywhere in the CSS.** Delete `.lv-scroll` entirely. Do not replace it with
   `overflow-x: hidden` — hiding overflow conceals clipped content instead of reflowing it.
2. **No `white-space: nowrap` anywhere.** `.lv-th` currently has it; it dies with the header row.
3. **`min-width: 0` on every flex/grid child that contains text** (`.cbs-tile-head` children,
   `.cbs-tile` itself). This is the actual mechanism: a flex item's default `min-width: auto`
   refuses to shrink below its longest unbreakable token, so one long email address forces the
   whole row wider than the container. Omitting this single declaration reintroduces the defect.
4. **`overflow-wrap: anywhere` on `.cbs-tile`.** `overflow-wrap` is an *inherited* CSS property
   and inherited properties cross the shadow boundary, so this reaches the `<a>` inside
   `lightning-formatted-email`'s own shadow root — which is otherwise unreachable from this
   bundle's stylesheet. Use `anywhere`, **not** `break-word`: only `anywhere` affects
   min-content size, which is what lets the flex/grid item actually shrink.
5. **Grid track must be `minmax(min(18rem, 100%), 1fr)`**, never a bare `minmax(18rem, 1fr)`.
   A bare 18rem minimum overflows any container narrower than 288px. The `min(…, 100%)` clamp
   is the fix.
6. **No fixed pixel widths, no `table-layout`, no `flex-basis` in px** on any content element.

### 2.5 Behaviour in a wide region (must still look deliberate)

`.cbs-list` is a CSS grid:

```
display: grid;
grid-template-columns: repeat(auto-fill, minmax(min(18rem, 100%), 1fr));
gap: var(--slds-g-spacing-3, 12px);
```

- In the **sidebar** (~360px): one column. A clean vertical stack.
- In the **main region** (~700px+): two or three tiles per row automatically — a card grid, not a
  lonely stretched column.

No media queries: a media query measures the *viewport*, but the constraint here is *container*
width, and the same viewport yields a 360px sidebar or a 900px main region. `auto-fill` responds
to actual container width and needs no container-query support.

---

## 3. (b) WHAT MUST BE PRESERVED — verified against the current code, item by item

| # | Item | Where it lives now | Disposition |
| --- | --- | --- | --- |
| 1 | Record count in the card title | `<span slot="title">Competing Broker Submissions ({count})</span>`, `get count()` | **Keep verbatim.** Title markup and the `count` getter are unchanged. |
| 2 | Winner-vs-competing badge | `WINNER_BADGE`/`COMPETING_BADGE` + `BADGE_CLASS` map, `lightning-badge` with `label`/`class` | **Keep.** JS constants and map unchanged; only the badge's position in the markup moves. |
| 3 | Winner accent treatment | `.lv-row_winner` (tinted surface + 3px inset success stripe) | **Keep**, re-homed onto `.cbs-tile_winner`. Same declarations, same tokens. |
| 4 | Clickable email links | `lightning-formatted-email` for broker email **and** forwarded-by | **Keep both.** Same component, same `value` binding. Not downgraded to plain text. |
| 5 | `—` fallback for a missing forwarded-by | `<template lwc:else><span class="lv-muted">—</span>` | **Keep**, on `.cbs-muted`. |
| 6 | `—` fallback for missing name/address | `EM_DASH` in the `rows` getter | **Keep.** JS unchanged. |
| 7 | Formatted submitted date/time | `lightning-formatted-date-time` with `year=numeric month=short day=2-digit hour=2-digit minute=2-digit` | **Keep all five attributes verbatim.** The existing Jest test asserts `dt.value`; the format attributes are what make it legible in a narrow tile. |
| 8 | Inline error banner | `<div class="lv-error … slds-text-color_error" role="alert">` | **Keep verbatim, class name included** — `.lv-error` is the one genuinely cross-bundle class (PC-2). |
| 9 | Companion error toast | `ShowToastEvent` in `wiredSubmissions` | **Keep verbatim.** Untouched JS. |
| 10 | Empty state | `.lv-empty` + `utility:info` icon + `role="status"` + copy "No broker submissions are on record for this lead." | **Keep, rename class to `.cbs-empty`.** Icon, `role="status"` and the copy string are unchanged. |
| 11 | Row ordering | selector `ORDER BY Submitted_DateTime__c ASC` | **Keep.** No client-side sort. |
| 12 | `lightning-card icon-name="standard:lead"` | template line 2 | **Keep.** |

### 3.1 No field is dropped

All five displayed fields survive. **Nothing is hidden or removed.**

### 3.2 One explicit DEMOTION — `Forwarded_By_Email__c`

**Recommendation:** keep the field, keep it as a live `lightning-formatted-email`, but move it to
the **last** row of the tile's `<dl>`, at `--slds-g-font-scale-neg-1` in
`--slds-g-color-neutral-base-60`.

**Justification:** it is near-constant across rows — every inbound broker email in this pipeline
arrives broker → DPEG coordinator → the Salesforce email service, so `Forwarded_By_Email__c`
is the coordinator's mailbox on essentially every row (the screenshot shows the same
`bestbankaiagent@gmail.com` on both). A field with no row-to-row variance carries no
discriminating value for the reviewer's actual question ("which broker claimed this?"), so it
should not compete for the top of the tile. It is **not** dropped, because it is the transport
evidence behind the U1 "envelope sender is the broker" rule and the paste-forward guard
(`From_Address__c == Forwarded_By__c`) — a reviewer adjudicating a disputed claim needs it.

**This is the only change in relative prominence. Flag it at the confirmation gate** (§9, D1).

### 3.3 Two options considered and explicitly DECLINED (do not build)

- **Hoist a shared property address to a panel-level subtitle when all rows match.** Reads well
  in the common case, but needs new comparison logic in JS, and is wrong the moment two rows
  carry different addresses. Adds scope. **Declined.**
- **Add a "View All" footer to match `recentLeads` / `recentOpportunities`.** The component has
  never had one and there is no list view to link to. Adding it is scope creep. **Declined.**

---

## 4. (c) THE HOUSE-STANDARD DEVIATION — stated plainly

**This change retires a hand-rolled `<table>` that exists in exactly one bundle. It does not
leave a shared design family, because — per PC-2 — this component was never in one.**

What is genuinely shared, and is **kept**:

- `lightning-card` with an `icon-name` and a `slot="title"` reading `Title (count)` ✅ kept
- the `.lv-error` inline banner div, class name and all ✅ kept verbatim

What is private to this bundle, and is **replaced**: `.lv-scroll`, `.lv-table`, `.lv-head`,
`.lv-th`, `.lv-cell`, `.lv-row`, `.lv-row_winner`, `.lv-name`, `.lv-sub`, `.lv-muted`,
`.lv-empty`, `.lv-empty-text`, `.lv-empty-icon`.

### Why not adopt the real house standard (`c-list-datatable`)?

Because it does not solve the reported problem. `lightning-datatable` ships its own horizontal
scroll container and minimum column widths; `wrap-text` and `column-widths-mode="auto"` reduce
but do not eliminate it. Dropping `c-list-datatable` into a ~360px sidebar with five columns
reproduces the exact scrollbar in the screenshot. **The narrow-region constraint is what forces
the deviation** — a tabular presentation of any kind, house-standard or hand-rolled, needs
horizontal room this region does not have.

### Naming: replace `lv-`, do not retain it

**Recommendation: rename the bundle-private classes to a `cbs-` prefix** (`cbs-list`, `cbs-tile`,
`cbs-tile_winner`, `cbs-tile-head`, `cbs-broker`, `cbs-email`, `cbs-fields`, `cbs-label`,
`cbs-value`, `cbs-muted`, `cbs-empty`, `cbs-empty-text`, `cbs-empty-icon`). Keep `.lv-error`.

Reasons: (1) `lv-` reads as "list view" and signals membership in a table family the markup no
longer belongs to — keeping it on tiles is a false family resemblance that will mislead the next
reader; (2) a bundle-local prefix is already the repo's convention for non-datatable components
(`rt-` in `renewalTimeline`); (3) `.lv-error` staying put preserves the resemblance where the
resemblance is real.

### Other list LWCs with the same defect — noted, NOT in scope

- `rentRoll.css` line 36 `.scroll { overflow-x: auto; }` — but it lives in the **`main`** region of
  `Property_Asset_Record_Page` inside a tab, is full-width, and a rent roll legitimately has many
  columns. Not a defect there.
- `recentLeads` / `recentOpportunities` (`Lead_Funnel` `region2`) and `renewalList`
  (`Lease_Renewals_Home`) use `c-list-datatable`, which carries datatable's own horizontal
  scroller. They are on wide app-home templates, not a record-page sidebar. **If any is later
  placed in a narrow column it will show the same class of defect.**

**Do not touch any of them in this change.**

---

## 5. (d) STYLING RULES

- **SLDS 2 design tokens only.** No new hardcoded colours or spacing. The current CSS is already
  correct — match its style exactly, including the `var(--token, fallback)` form.
- **Reuse only tokens already present in this repo**, with the same fallback values, so no token
  is invented: `--slds-g-color-surface-container-1`, `--slds-g-color-border-base-1`,
  `--slds-g-color-neutral-base-10 / -30 / -60`, `--slds-g-color-success-base-50`,
  `--slds-g-spacing-2 / -3 / -4 / -5`, `--slds-g-font-scale-neg-2 / neg-1 / base`,
  `--slds-g-font-weight-7`, `--slds-g-sizing-border-1`, `--slds-g-radius-border-2`.
- `:host { display: block; color: var(--slds-g-color-neutral-base-10, #181818); }` — keep as is.
- SLDS utility classes (`slds-p-around_medium`, `slds-text-color_error`, `slds-theme_success`,
  `slds-badge_inverse`) stay as they are.
- Run the SLDS linter before deploying (ARCHITECTURE.md §5).
- **`apiVersion` stays 67.0.** `js-meta.xml` is not edited at all.

---

## 6. (e) ACCESSIBILITY — what replaces the table semantics

The current `<table>` + `<th scope="col">` gives screen-reader users a genuine
**column-header → cell** association, plus `aria-label` on the table. That value must be
replaced, not lost:

| Lost semantic | Replacement |
| --- | --- |
| `<table aria-label="Competing broker submissions">` | `<ul class="cbs-list" aria-label="Competing broker submissions">` — same label, list semantics announce "list, N items" (which also voices the count). |
| `<tbody><tr>` = one record | `<li class="cbs-tile">` = one record. |
| `<th scope="col">` ↔ `<td>` field association | A `<dl>` per tile: `<dt>` carries the field label ("Submitted", "Property Address", "Forwarded By") and `<dd>` the value. `dt`/`dd` is the direct semantic equivalent of header→cell for a single record, and unlike a table it needs no horizontal room. |
| Row identity | The broker name is an `<h3>` inside the `<li>`, giving each tile an accessible name and letting screen-reader users jump tile to tile by heading. |
| Status column header | The badge sits in the tile head, preceded by `<span class="slds-assistive-text">Status:</span>` so it is not announced as a bare orphan word. |

Additional rules:

- **The `<dl>` must contain only `<dt>`/`<dd>` in valid order** (no `<div>` wrappers) — axe's
  `definition-list` rule is strict, and `<dl>` + CSS grid works without wrappers.
- The labels are **visible text**, not `slds-assistive-text`. In a narrow tile the sighted user
  needs them too — without the column headers, `intake@dpeg.com` on a bare line is unidentifiable.
- `role="alert"` on the error banner and `role="status"` on the empty state are **kept as is**.
- `h3` is correct: `lightning-card`'s title renders as an `h2`, so `h3` continues the hierarchy
  without a skipped level (an axe `heading-order` finding).
- `@sa11y/jest` `toBeAccessible()` must still pass — see §7 T5.

---

## 7. (f) TESTING — which assertions change, and the new no-scroll pin

File: `force-app/main/default/lwc/competingBrokerSubmissions/__tests__/competingBrokerSubmissions.test.js`
The mock/fixture/`flushPromises` scaffolding at the top is unchanged.

### Assertions that MUST change (they are table-shaped and will break)

| Line(s) | Current | Change to |
| --- | --- | --- |
| 77–78 | `querySelectorAll('tbody tr')` → length 2 | `querySelectorAll('.cbs-tile')` → length 2 |
| 112 | `querySelector('tbody')` toBeNull (empty state) | `querySelector('.cbs-list')` toBeNull |
| 134 | `querySelector('tbody')` toBeNull (error path) | `querySelector('.cbs-list')` toBeNull |
| 111 | `querySelector('.lv-empty')` not null | `querySelector('.cbs-empty')` not null |

### Assertions that must NOT change (they are behaviour, not markup)

- title text `'Competing Broker Submissions (2)'` (line 81–83)
- badge labels contain `Winner` and `Competing` (86–90)
- `lightning-formatted-email` values contain both broker addresses (93–97)
- `lightning-formatted-date-time` `.value` (100–102)
- the whole ERROR PATH toast block (119–130) and `.lv-error` presence (133)

### NEW assertions

**T1 — the direct anti-regression pin (the one the brief asks for):**
```js
expect(element.shadowRoot.querySelector('table')).toBeNull();
```
Also assert `querySelector('.lv-scroll')` and `querySelector('thead')` are null. A test that
merely renders would not catch a revert to a table; this does, in one line.

**T2 — the CSS-source pin (the strongest available; read this justification before objecting):**
```js
const css = require('fs').readFileSync(
    require('path').join(__dirname, '..', 'competingBrokerSubmissions.css'), 'utf8');
expect(css).not.toMatch(/overflow-x/);
expect(css).not.toMatch(/white-space\s*:\s*nowrap/);
expect(css).toMatch(/min-width\s*:\s*0/);
expect(css).toMatch(/overflow-wrap\s*:\s*anywhere/);
```
**Why a source-text assertion and not a measurement:** jsdom performs no layout. `scrollWidth`,
`clientWidth`, `offsetWidth` and `getBoundingClientRect()` all return **0** in this environment,
so the obvious test — "assert `scrollWidth <= clientWidth`" — is `0 <= 0` and passes **whether or
not the component overflows**. That is a vacuously-green test, and a green test nobody looks at is
worse than a missing one. A source-text assertion is coarse but it is *falsifiable*: it goes red
the moment someone reintroduces `overflow-x` or a `nowrap`, or deletes the two declarations
(rules 3 and 4 of §2.4) that do the actual work.
Put the reasoning in a comment above the test so review does not "improve" it into a
measurement.

**T3 — the field labels survived the loss of `<th>`:**
```js
const labels = [...element.shadowRoot.querySelectorAll('dt')].map(d => d.textContent.trim());
expect(labels).toEqual(expect.arrayContaining(['Submitted', 'Property Address', 'Forwarded By']));
```
This is what proves the `<th scope="col">` semantics were replaced rather than deleted (§6).

**T4 — the winner accent is applied to the winner and only the winner:**
```js
const tiles = element.shadowRoot.querySelectorAll('.cbs-tile');
expect(tiles[0].className).toContain('cbs-tile_winner');   // fixture row 1 is the winner
expect(tiles[1].className).not.toContain('cbs-tile_winner');
```
The current suite asserts badge *labels* but never the row accent — this closes a real gap.

**T5 — accessibility, kept and unchanged:** `await expect(element).toBeAccessible();` must still
pass against the new `ul`/`li`/`h3`/`dl` markup. If axe reports `definition-list` or
`heading-order`, the markup is wrong — fix the markup, never loosen the assertion.

Jest is local/CI only (`.forceignore` excludes `**/__tests__/**`); nothing here deploys.

---

## 8. (g) BLAST RADIUS — presentation only

| Layer | Change required? |
| --- | --- |
| `CompetingSubmissionController.cls` | **NONE** |
| `CompetingBrokerSubmissionSelector.cls` | **NONE** |
| Any Apex, trigger, service, test class | **NONE** |
| `Competing_Broker_Submission__c` object/fields | **NONE** |
| `Lead_Record_Page.flexipage-meta.xml` | **NONE** — see below |
| Permission sets, profiles, FLS | **NONE** |
| `competingBrokerSubmissions.js-meta.xml` | **NONE** (stays 67.0) |
| `competingBrokerSubmissions.html` | **YES** — the table block only |
| `competingBrokerSubmissions.css` | **YES** — replace the `.lv-*` table chrome |
| `competingBrokerSubmissions.js` | **YES, minimal** — only the class-name strings in the `rows` getter (`rowClass: 'lv-row lv-row_winner'` → `'cbs-tile cbs-tile_winner'`). `WINNER_BADGE`, `COMPETING_BADGE`, `BADGE_CLASS`, `EM_DASH`, the wire handler, `errorMessageText`, `hasSubmissions` and `count` are all **untouched**. |
| `__tests__/competingBrokerSubmissions.test.js` | **YES** — §7 |

The wire, the Apex contract, the field set and the query are all unchanged. The component reads
the same seven fields it reads today.

**Flexipage — called out, NOT assumed.** The component stays in the `sidebar` region. Moving it
to `main` would be a *separate* decision with a different rationale (it would widen the panel but
push it below the fold and out of the contextual column), and it is **not** required by this
change — the point of the redesign is that the sidebar becomes the right home for it. Raised as
D2 in §9.

---

## 9. DECISIONS FOR THE CONFIRMATION GATE

| # | Decision | Recommendation |
| --- | --- | --- |
| **D1** | `Forwarded_By_Email__c` demoted to the last line of the tile (kept, still a clickable link, just muted and last) — §3.2 | **Accept.** It is near-constant across rows and carries no discriminating value at the top of the tile. |
| **D2** | Leave the component in the `sidebar` region (no flexipage change) | **Accept.** The redesign makes the sidebar work; moving to `main` is a separate decision. |
| **D3** | Rename bundle-private `.lv-*` classes to `.cbs-*`, keep `.lv-error` — §4 | **Accept.** `lv-` implies a table family the markup leaves. |

---

## 10. ADJACENT — NOTED, NOT IN SCOPE

`CompetingBrokerSubmissionSelector.selectByWinningLead` is Lead-anchored only, so once a winning
Lead converts, `Winning_Opportunity__c`-anchored submissions have no UI surface (documented in
the selector Javadoc and ARCHITECTURE.md §1 as a known-open, separately-filed item). **This
change does not touch it and must not.** It requires a sibling `selectByWinningOpportunity`, a
controller method and an Opportunity flexipage placement — a different piece of work.

---

## 📝 PROMPT FOR salesforce-developer

```
Rework the presentation of the existing LWC bundle
force-app/main/default/lwc/competingBrokerSubmissions so that NOTHING in it scrolls
horizontally at any container width. It sits in the `sidebar` region of
Lead_Record_Page.flexipage-meta.xml (~360px wide); the current 5-column
<table class="lv-table"> inside <div class="lv-scroll"> (overflow-x: auto) is the defect.

Presentation only. Do NOT change any Apex, selector, controller, object metadata,
permission set, or flexipage. Do NOT change competingBrokerSubmissions.js-meta.xml
(apiVersion stays 67.0). Do not add features, fields, footers or list views that are not
already there.

MARKUP (competingBrokerSubmissions.html) — replace ONLY the .lv-scroll/table block:
  ul.cbs-list  aria-label="Competing broker submissions"
    li.cbs-tile  (+ cbs-tile_winner when the row is the winner)
      div.cbs-tile-head  → h3.cbs-broker {row.brokerName}
                         + <span class="slds-assistive-text">Status:</span>
                         + <lightning-badge label={row.badgeLabel} class={row.badgeClass}>
      lightning-formatted-email.cbs-email value={row.brokerEmail}  (inside its existing lwc:if)
      dl.cbs-fields  — dt/dd pairs ONLY, no div wrappers:
          dt "Submitted"        / dd lightning-formatted-date-time value={row.submittedDateTime}
                                     year="numeric" month="short" day="2-digit"
                                     hour="2-digit" minute="2-digit"   (keep all five attributes)
          dt "Property Address" / dd {row.propertyAddress}
          dt "Forwarded By"     / dd lightning-formatted-email value={row.forwardedByEmail},
                                     with the existing lwc:else "—" in <span class="cbs-muted">
Keep unchanged: <lightning-card icon-name="standard:lead">, the
<span slot="title">Competing Broker Submissions ({count})</span> title, the error branch
<div class="lv-error slds-p-around_medium slds-text-color_error" role="alert"> INCLUDING the
class name lv-error (it is shared with recentLeads/recentOpportunities/renewalList), and the
empty branch (role="status", utility:info icon, copy text) — rename only its classes
.lv-empty/.lv-empty-text/.lv-empty-icon → .cbs-empty/.cbs-empty-text/.cbs-empty-icon.

CSS (competingBrokerSubmissions.css) — delete .lv-scroll, .lv-table, .lv-head, .lv-th,
.lv-cell, .lv-row, .lv-row_winner, .lv-name, .lv-sub, .lv-muted, .lv-empty*. Keep :host and
.lv-error as they are. Add the cbs-* rules. These declarations are load-bearing:
  .cbs-list  { display:grid;
               grid-template-columns: repeat(auto-fill, minmax(min(18rem, 100%), 1fr));
               gap: var(--slds-g-spacing-3, 12px);
               padding: var(--slds-g-spacing-3, 12px) var(--slds-g-spacing-4, 16px);
               margin:0; list-style:none; }
  .cbs-tile  { min-width:0; overflow-wrap:anywhere;
               border: var(--slds-g-sizing-border-1,1px) solid var(--slds-g-color-border-base-1,#e5e5e5);
               border-radius: var(--slds-g-radius-border-2, 8px);
               padding: var(--slds-g-spacing-3, 12px); }
  .cbs-tile_winner { background: var(--slds-g-color-surface-container-1, #fafaf9);
                     box-shadow: inset 3px 0 0 var(--slds-g-color-success-base-50, #2e844a); }
  .cbs-tile-head { display:flex; flex-wrap:wrap; align-items:center;
                   justify-content:space-between; gap: var(--slds-g-spacing-2, 8px); }
  .cbs-broker { min-width:0; margin:0; font-weight: var(--slds-g-font-weight-7,700);
                font-size: var(--slds-g-font-scale-base,13px);
                color: var(--slds-g-color-neutral-base-10,#181818); }
  dt/label style: var(--slds-g-font-scale-neg-2,10px), uppercase-ish muted
                  var(--slds-g-color-neutral-base-60,#706e6b); dd { margin:0; min-width:0; }
HARD RULES: no overflow-x anywhere; no white-space:nowrap anywhere; min-width:0 on every
flex/grid child holding text; overflow-wrap:anywhere (NOT break-word — only `anywhere`
affects min-content sizing, and it inherits into lightning-formatted-email's shadow root);
grid minimum must be min(18rem,100%) not a bare 18rem; no fixed px widths on content.
SLDS 2 tokens only, var(--token, fallback) form, reusing the tokens listed above — no new
hardcoded colours or spacing. renewalTimeline is the structural precedent for the stacked
layout, but do NOT copy its hardcoded hex colours.

JS (competingBrokerSubmissions.js) — ONLY change the class strings in the `rows` getter:
rowClass 'lv-row' / 'lv-row lv-row_winner' → 'cbs-tile' / 'cbs-tile cbs-tile_winner'.
Leave WINNER_BADGE, COMPETING_BADGE, BADGE_CLASS, EM_DASH, the @wire handler, the toast,
errorMessageText, hasSubmissions and count exactly as they are. Do not re-sort rows — the
selector returns them oldest-first and that order is the contract.

Run the SLDS linter before finishing.
```

## 📝 PROMPT FOR salesforce-unit-testing (Jest, same bundle)

```
Update force-app/main/default/lwc/competingBrokerSubmissions/__tests__/competingBrokerSubmissions.test.js
for the tile markup. Keep the existing mock, SUBMISSIONS fixture and flushPromises helper.

CHANGE these four selectors only:
  'tbody tr' -> '.cbs-tile'  (happy path, still expects 2)
  'tbody'    -> '.cbs-list'  (empty-state toBeNull)
  'tbody'    -> '.cbs-list'  (error-path toBeNull)
  '.lv-empty'-> '.cbs-empty'
Do NOT change: the title-text assertion, the badge-label assertions, the
lightning-formatted-email value assertions, the lightning-formatted-date-time assertion,
the whole ERROR PATH toast block, or the '.lv-error' assertion.

ADD:
T1 no-table pin: expect(shadowRoot.querySelector('table')).toBeNull(); same for 'thead'
   and '.lv-scroll'.
T2 CSS-source pin — read competingBrokerSubmissions.css with fs.readFileSync and assert it
   does NOT match /overflow-x/ or /white-space\s*:\s*nowrap/, and DOES match /min-width\s*:\s*0/
   and /overflow-wrap\s*:\s*anywhere/. Put a comment above it explaining WHY this is a
   source-text assertion: jsdom performs no layout, so scrollWidth/clientWidth/
   getBoundingClientRect all return 0 and a "scrollWidth <= clientWidth" test would pass
   vacuously whether or not the component overflows. Do not replace it with a measurement.
T3 field labels: collect querySelectorAll('dt') textContent and assert it contains
   'Submitted', 'Property Address' and 'Forwarded By' — this is what proves the
   <th scope="col"> semantics were replaced rather than deleted.
T4 winner accent: '.cbs-tile' index 0 className contains 'cbs-tile_winner', index 1 does not.
T5 keep `await expect(element).toBeAccessible()` unchanged. If axe reports definition-list or
   heading-order, fix the MARKUP, never loosen the assertion.
```
