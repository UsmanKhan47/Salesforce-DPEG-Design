# DESIGN REQUIREMENTS — portfolioDealSiblings card-tile redesign

Date: 2026-08-19
Scope: visual redesign of `c/portfolioDealSiblings` only. LWC-only, no Apex.

---

## 0. PREMISES CHECKED AGAINST THE REPO

Verified before designing (the brief's detail is treated as hypothesis, not findings).

### Confirmed as stated

| Premise | Evidence |
|---|---|
| Card is `<lightning-card icon-name="standard:related_list">` with a "From one broker email: `<a>`" line, then a `<ul>` of rows | `portfolioDealSiblings.html` lines 8, 32-39, 48-62 |
| Classes `.pds-list` / `.pds-item` / `.pds-link` / `.pds-meta` / `.pds-line` | all five in `portfolioDealSiblings.css`; **17 occurrences across exactly 3 files** (html, css, test) — bundle-local, zero external consumers |
| Row meta text is `{row.objectLabel} · {row.status}` | `.html` line 57-59 |
| Placed on both `Lead_Record_Page` and `Opportunity_Record_Page` | `Lead_Record_Page` line 814, `Opportunity_Record_Page` line 1823 |
| Region is `sidebar` on both | Lead: region block 805-844, `<name>sidebar</name>` at 842. Opportunity: `<name>sidebar</name>` at 1841 |
| One bundle serves both pages; never split | `.js` header lines 9-21 |
| `SiblingRow.status` is raw `Lead.Status` / `Opportunity.StageName` | `PortfolioDealController.buildSiblings` lines 335-345; DTO comment line 415 |
| Empty / loading / error behaviour is deliberate | `.js` header lines 45-59; `.html` lines 2-6 |

### Contradicted or materially incomplete — read these before approving

**C1 — "The redesign will change the DOM structure (no more `<ul>/<li>`)." It should not, and does not need to.**
There is an in-repo precedent for this exact request: `c/competingBrokerSubmissions` sits in the **same `sidebar` region of the same `Lead_Record_Page`, one item above this component** (line 808 vs 814). It renders bordered card-tiles with a head row of heading + `lightning-badge` — and it **keeps `<ul>`/`<li>`**, styling the `<li>` as the tile (`.cbs-list` / `.cbs-tile`, css lines 45-60). Its own header records that it moved *to* `<ul>/<li>` *from* a `<table>` precisely to keep list semantics and stop sidebar overflow. Our component's markup carries the matching note: *"a semantic list is what a screen reader announces usefully here"* (`.html` lines 43-47).
**Consequence:** card-tile appearance is a CSS concern. Dropping `<ul>/<li>` would be an unforced accessibility regression against two documented decisions, and would churn the Jest suite far more than necessary. Recommendation below keeps the list and keeps `.pds-link`, so most existing test selectors survive.

**C2 — "no hardcoded colors" is not quite the house convention; the convention is token *with* a literal fallback.**
Both this bundle (`var(--slds-g-color-brand-base-50, #0176d3)`, css line 36) and `competingBrokerSubmissions` (`var(--slds-g-color-border-base-1, #e5e5e5)`, css line 57) deliberately pair every `--slds-g-*` token with a hex fallback, and this bundle's css header states why: *"with a plain fallback for each so the card still reads correctly if a token is unavailable."* The rule is "no hardcoded **brand** colours as the value", not "no hex anywhere". The developer must follow the existing pattern; a reviewer should not strip the fallbacks.

**C3 — `objectLabel` is not a stable literal. It is a describe-derived, admin-renameable, translated label.**
`PortfolioDealController` lines 355-356:
```apex
private static final String LEAD_LABEL = Lead.SObjectType.getDescribe().getLabel();
private static final String OPPORTUNITY_LABEL = Opportunity.SObjectType.getDescribe().getLabel();
```
with the stated intent *"so the card says whatever the org calls them rather than a hardcoded English string"* (line 353-354).
Two consequences the brief does not account for:
- a client-side `objectLabel === 'Lead'` comparison **silently stops matching** if an admin renames the Lead tab label or a user runs a translated locale;
- the Jest fixtures hardcode `objectLabel: 'Lead'` / `'Opportunity'` (test lines 85, 93), so **the suite stays green while the icon is wrong in the org** — the exact failure mode this bundle's headers warn about three separate times (`.js` lines 140-148, test lines 68-74).
This does not veto the user's approved approach, but it makes a **generic default icon mandatory** rather than optional (see D2).

**C4 — Replacing the "objectLabel · status" text with icon + badge deletes `objectLabel` from the accessible name and from plain reading.**
An icon conveys object type to a sighted user who knows the iconography, and to nobody else. There is an existing test whose stated purpose is exactly this: *"A Lead row and an Opportunity row must be distinguishable to a human WITHOUT the client knowing either object exists"*, asserting `.pds-meta` contains `Lead` / `Opportunity` (test lines 193-208). Losing that text also wastes the server-side describe in C3. **This needs a decision (D1) — it is the one part of the request that is not purely cosmetic.**

**C5 — The `sidebar` region is ~360px, and the status badge is new unbreakable content.**
`competingBrokerSubmissions.css` lines 41-43 record the constraint: *"the same viewport yields a ~360px record-page sidebar or a ~900px main region"*, so container width — not viewport — is the constraint and media queries are the wrong tool. Our current CSS already fights this with `min-width: 0`, `overflow-wrap: anywhere`, `flex-wrap: wrap` (css lines 18-51). A status pill carrying a long stage value is a new overflow risk that today's plain text does not have.
Also noted in that CSS: *"jsdom performs no layout, so a Jest test CANNOT observe overflow... verified by eye in the org, not by the suite."* This redesign therefore needs a **manual visual check in the org** as an explicit acceptance step.

**C6 — `<ul class="slds-has-dividers_bottom-space pds-list">` must lose the divider class.**
Bordered tiles plus SLDS bottom dividers renders a double rule between rows.

---

## 1. BLOCKING DECISIONS

These change the deliverable. Please answer D1 and D2; D3/D4 default to "not included."

**D1 — What happens to `objectLabel`?** (see C4)
- **D1-a (recommended):** keep `objectLabel` as short visible text in the tile, move only `status` into the neutral badge. Icon is decorative. Every existing tested fact stays true; the change is genuinely "visual polish only."
- **D1-b (as literally briefed):** icon replaces the `objectLabel` text entirely. Requires giving the icon `alternative-text={row.objectLabel}` so screen readers still get it, and accepts that sighted users read object type from iconography alone. The existing `.pds-meta` label test must be rewritten to assert the icon's alt text instead.

**D2 — How is the icon chosen?** (see C3)
- **D2-a (recommended):** map `objectLabel` → icon with a **generic default** for any unrecognised label (`standard:lead`, `standard:opportunity`, else `standard:record`). The default is what preserves the documented "a third object can be added with **zero** client changes" property — the `Transaction__c` precedent in `.js` lines 16-18 and `PortfolioDealController` lines 76-81. Without a default, adding a third object or renaming a label yields a broken/blank icon.
- **D2-b (simplest):** one generic icon on every row, no branching at all. Fully object-agnostic, zero fragility, but rows are visually undifferentiated.

**D3 — `role="list"` + `aria-label` on the `<ul>`?** NOT included by default (not requested). Flagged because the neighbouring card documents that `list-style: none` makes WebKit drop the implicit `list` role, and *"axe has no rule for it, so the toBeAccessible() test passing is not evidence against it"* (`competingBrokerSubmissions.html` lines 26-33). Our `.pds-list` already sets `list-style: none` today, so omitting this is parity with current behaviour, not a regression.

**D4 — CSS source-text anti-regression test?** NOT included by default (not requested). Flagged because `competingBrokerSubmissions.test.js` (lines 33-47, T2) reads its own `.css` with comments stripped and asserts no `nowrap` / `overflow-x` / fixed widths — the established answer to "jsdom cannot measure layout" (C5).

---

## 2. WHAT THE USER REQUESTED

Convert each sibling row in `c/portfolioDealSiblings` from a plain text line into a compact bordered card-tile containing an icon, the record name link, and a **neutral** status badge replacing the current plain `objectLabel · status` text. Visual only — no data or behaviour change, no Apex change.

---

## 3. ADMIN WORK (salesforce-admin)

No admin work required for this request. No metadata objects, fields, permission sets, or flexipage changes — placement and region are unchanged on both record pages.

---

## 4. DEVELOPMENT WORK (salesforce-developer)

Standard LWC work. Not integration, not performance-critical → `salesforce-developer`, not `salesforce-technical-architect`.

- **`portfolioDealSiblings.html`** — restructure the sibling row into a tile: decorative `lightning-icon`, the existing `.pds-link` anchor, and a `lightning-badge` carrying `row.status`. Keep `<ul>`/`<li>` (C1). Drop `slds-has-dividers_bottom-space` (C6). Preserve unchanged: the `if:true={isVisible}` gate, the card title `Portfolio Deal ({count})`, the `hasError` branch with `.lv-error` + `role="alert"`, the "From one broker email:" `.pds-line` heading with the server-built `dealUrl`, and the R6 "No other records were created from this email." branch.
- **`portfolioDealSiblings.css`** — tile styling on `.pds-item` (border, radius, padding) using `var(--slds-g-*, fallback)` per C2, mirroring `.cbs-tile`. Keep `min-width: 0` and `overflow-wrap: anywhere`; keep `flex-wrap: wrap` so the badge wraps below the name rather than widening the tile; add wrap handling for the badge (C5). No `nowrap`, no `overflow-x`, no fixed pixel widths, no media queries.
- **`portfolioDealSiblings.js`** — add only the per-row display derivation needed for D1/D2 (a mapped getter over `siblings`; the wire handler's assignments stay as they are). **Do not** add a schema import, do not branch on `objectApiName`, do not compose a URL, do not add a spinner or an `isLoaded` gate.
- **Header comments** — record this redesign and the D1/D2 rationale in the `.js` class header and the `.css` header. This codebase treats headers as authoritative decision history, and the icon-mapping fragility in C3 is exactly the kind of fact that must be written down where the next editor will hit it.
- **`__tests__/portfolioDealSiblings.test.js`** — update in the same change (not a separate step): the `.pds-meta` label/status assertions become badge (and, per D1, icon) assertions; add a case proving an **unrecognised `objectLabel` falls back to the generic icon** (this is the C3 falsifier and the one new test that earns its place); keep both `toBeAccessible()` tests; keep the "renders nothing" test first and untouched — its own header calls it the most important test in the file.

**Explicitly out of scope:** `PortfolioDealController.cls`, `PortfolioDealSelector.cls`, any Apex or Apex test; the `c/recentPortfolioDeals` bundle; `Lead_Record_Page` / `Opportunity_Record_Page`; the bundle's `masterLabel` and `<description>` in `.js-meta.xml`.

**Two traps worth naming to the developer:**
1. Do not edit the `.js-meta.xml` `<description>` — it is ~210 chars against a **255-char cap that only a deploy catches** (Jest, the SLDS linter and code review all pass a 258-char one).
2. `.pds-*` classes are bundle-local (css header lines 4-9). `.lv-error` is the one genuinely cross-bundle class in this file — do not rename or restyle it.

---

## 5. EXECUTION ORDER

1. **D1 + D2 answered** — the markup and the test list both depend on them.
2. `salesforce-developer` — HTML + CSS + JS + Jest, one change.
3. `salesforce-code-review` — required for LWC per the routing table.
4. `salesforce-devops` + `salesforce-documentation` in parallel, after review passes.

No unit-testing agent step: no Apex is created or changed, and the Jest updates are in the developer's scope.

**Acceptance beyond a green suite:** open a Lead and an Opportunity that belong to a multi-property portfolio deal and confirm no horizontal scroll in the ~360px sidebar with a long property name and a long stage value. jsdom cannot observe this (C5).

---

## 6. PROMPT FOR salesforce-developer

> Redesign the sibling rows in `force-app/main/default/lwc/portfolioDealSiblings/` from plain text lines into compact bordered card-tiles. Visual polish only — no data or behaviour change, and **no Apex change**.
>
> Read first, and treat their header comments as binding: the bundle's four files, its `__tests__/portfolioDealSiblings.test.js`, `force-app/main/default/classes/PortfolioDealController.cls`, and `force-app/main/default/lwc/competingBrokerSubmissions/` (html + css + test) — that last one is the in-repo precedent for this exact pattern and sits in the same `sidebar` region of the same Lead record page.
>
> Each row becomes a tile with: a decorative `lightning-icon`, the existing `.pds-link` record-name anchor, and a `lightning-badge` carrying `row.status`.
>
> - **Badge is ONE neutral treatment for every row.** No colour-coding by outcome. `status` is raw `Lead.Status` / `Opportunity.StageName` (`PortfolioDealController` DTO line 415), the values are admin-editable, and the client is deliberately blind to which object a row is — any string-keyed colour map would be both fragile and a breach of that design.
> - **Icon:** [D2 answer inserted here]. If a mapping is used it must key off `row.objectLabel` only, with a generic default for any unrecognised value. Never import object schema, never branch on `objectApiName`.
> - **`objectLabel` handling:** [D1 answer inserted here].
> - **Keep `<ul>`/`<li>`** — style the `<li>` as the tile, as `.cbs-tile` does. Remove `slds-has-dividers_bottom-space` from the `<ul>` (borders + dividers double up).
> - **CSS:** `var(--slds-g-*, <fallback>)` throughout, matching the existing file and `.cbs-tile`. Keep `min-width: 0`, `overflow-wrap: anywhere`, `flex-wrap: wrap`; make sure a long status value in the badge cannot burst the ~360px sidebar. No `nowrap`, no `overflow-x`, no fixed pixel widths, no media queries (the constraint is container width, not viewport).
> - **Unchanged:** the `isVisible` gate (no card at all when there is no portfolio deal), no spinner and no `isLoaded` gate, the `Portfolio Deal ({count})` title, the `.lv-error` + `role="alert"` error branch, the `.pds-line` deal heading with the server-built `dealUrl`, and the R6 "No other records were created from this email." branch. All are deliberate and documented in the bundle's headers.
> - **Do not** touch `PortfolioDealController.cls`, `PortfolioDealSelector.cls`, any Apex test, the `c/recentPortfolioDeals` bundle, either flexipage, or the `.js-meta.xml` `masterLabel` / `<description>` (that description is ~210 chars against a 255-char cap that only a deploy catches).
> - Record the redesign and the icon-fallback rationale in the `.js` and `.css` header comments — this repo's headers are the authoritative decision history.
>
> **Update the Jest suite in this same change.** Rework the `.pds-meta` assertions into badge (and icon, per D1) assertions; add a test proving an **unrecognised `objectLabel` falls back to the generic icon** — the fixtures hardcode `'Lead'`/`'Opportunity'`, but Apex supplies `getDescribe().getLabel()`, which is admin-renameable and translated, so without that test a renamed org breaks the icons while the suite stays green. Keep both `toBeAccessible()` tests and leave the "renders nothing" test first and untouched. Run the SLDS linter and Jest before handing off. Do not deploy.

---

## 7. NOT INCLUDED (would be scope creep — say the word if you want any of them)

- `role="list"` / `aria-label` on the `<ul>` (D3)
- CSS source-text anti-regression test (D4)
- Any change to the card's own `standard:related_list` icon, its title, or its wording
- Hover/focus states, animation, density toggles, or empty-state restyling
