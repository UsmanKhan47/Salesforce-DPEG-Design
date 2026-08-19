# Lead Record Page Comment Restoration + Portfolio Deal Siblings Card-Tile Redesign

**Date:** 2026-08-19
**Author:** Documentation Agent
**Status:** Both items deployed to `usman-dpeg`. Item 1 is documentation-only (zero deployable effect). Item 2 is LWC-only (no Apex, no metadata objects); code review passed after two non-behavioral fixes were applied and re-verified.

---

## 📋 Overview

### Original Request

Two changes to the `portfolioDealSiblings` component chain, documented together because both touch
the same bundle/page relationship:

> **Item 1** — A user made intentional structural changes directly in Salesforce App Builder on
> `Lead_Record_Page` (renamed "Deal Intake" → "Property & Deal Terms" and "Deal Screening" →
> "Process & Tracking", rebalanced which of the 38 relevant Lead fields live in which section,
> removed `Broker_First__c` and `DPEG_First__c` from the page, deleted the "Broker" tab, added a
> visibility rule to `Disqualification_Reason__c`). These were retrieved into the repo from the live
> org. The retrieve round-trip lost a 13-line local-only XML comment (the Metadata API does not store
> XML comments) documenting the `packageSiblings` → `portfolioDealSiblings` LWC bundle-rename hazard
> in the sidebar region. Restore that comment verbatim at its original location.
>
> **Item 2** — Redesign `force-app/main/default/lwc/portfolioDealSiblings/` (placed on both
> `Lead_Record_Page` and `Opportunity_Record_Page` sidebar regions) from a plain bulleted list of
> sibling deal records into compact bordered card-tiles, for visual polish only — no data or
> behaviour change, no Apex change.

### Business Objective

- **Item 1** exists because a comment is the only mechanism this repo has for warning a future editor
  that an LWC bundle rename is a delete-and-create: a FlexiPage that still names the old
  `componentName` (`packageSiblings`) renders **nothing and reports no error**, which on this
  particular component is indistinguishable from its own correct, common "no portfolio deal" state.
  Losing that warning silently on every retrieve is a standing risk to the next person who edits this
  page in App Builder — the comment does not affect org behaviour, but its absence removes the one
  thing that would stop a future silent regression.
- **Item 2** exists purely as visual polish on an already-shipped feature (the Portfolio Deal
  siblings card, itself the product of the 2026-08-17 Multi-Property Email Grouping work and the
  2026-08-17/18 Portfolio Deal rename program) — no new capability, no new data.

### Summary

Item 1 re-inserted a 13-line XML comment, byte-for-byte, at its original location in
`Lead_Record_Page.flexipage-meta.xml`, immediately before the `<itemInstances>` block that places
`c/portfolioDealSiblings`. It has no effect on deployed behaviour — comments are stripped by the
Metadata API on every retrieve, which is exactly the defect this restoration is patching around (the
comment will need to be re-applied after any future retrieve of this file, a known and accepted
limitation, not a bug in this change).

Item 2 restyled each sibling row from a plain text line (`{objectLabel} · {status}` under the record
link) into a compact bordered `<li>` tile: a decorative icon mapped from `objectLabel`, the existing
record-name link, the `objectLabel` text (kept, unchanged from before), and a new neutral
(non-color-coded) `lightning-badge` carrying the raw `status` value. The redesign deliberately kept
the `<ul>/<li>` markup rather than moving to `<div>`s, following an in-repo precedent
(`c/competingBrokerSubmissions`, same sidebar region, same `Lead_Record_Page`) that solved the
identical "card-tile look without losing list semantics" problem first. Code review found two
non-behavioral issues on the first pass (APPROVED WITH WARNINGS); both were fixed and re-verified
before deployment.

---

## 🏗️ Components Created / Modified

### Item 1 — Admin Components (Declarative)

#### FlexiPages

| FlexiPage | Change |
|-----------|--------|
| `Lead_Record_Page` | Restored a 13-line XML comment, immediately before the `<itemInstances>` block placing `componentName>portfolioDealSiblings`, at lines 812-824. **Comment only — zero functional/deployable effect.** |

The comment's restored text (confirmed present in the file as of this doc):

```xml
<!--
    Multi-Property Email Grouping (2026-08-17; bundle renamed from packageSiblings in phase B4
    of the Portfolio Deal rename, 2026-08-18). c-portfolioDealSiblings is object-agnostic
    (recordId + objectApiName only, no schema import) and is placed identically on
    Opportunity_Record_Page.flexipage-meta.xml per ARCHITECTURE.md section 5's
    "one bundle, not one per object" precedent. It renders nothing when the Lead has no
    Portfolio_Deal__c (the common single-property case) - never an empty card.

    An LWC bundle rename is a delete-and-create, so componentName had to move with it: a page
    still naming `packageSiblings` renders NOTHING and reports no error - which on THIS
    component is indistinguishable from its correct, common "no deal" state. Read this page
    back after deploying, and confirm the card on a Lead that HAS a portfolio deal.
-->
```

#### Context — the App Builder changes this file already reflects (not made by this task, verified present)

These structural changes were made directly in App Builder by a user and retrieved into the repo
before this documentation task began. They are recorded here for completeness since they are now
part of `Lead_Record_Page`'s current state, but **no agent in this task authored them**:

| Change | Verified in file |
|---|---|
| Section "Deal Intake" renamed to "Property & Deal Terms" | `<value>Property & Deal Terms</value>` at line 662 |
| Section "Deal Screening" renamed to "Process & Tracking" | `<value>Process & Tracking</value>` at line 680 |
| `Broker_First__c` / `DPEG_First__c` removed from the page | Neither field appears anywhere in the file |
| "Broker" tab deleted | Remaining `flexipage:tab` titles are `Details`, `Standard.Tab.activity`, `Standard.Tab.files` only — no `Broker` tab |
| Visibility rule added to `Disqualification_Reason__c` | `RecordDisqualification_Reason_cField` now carries a `visibilityRule` (`{!Record.Status} EQUAL Qualified`) — lines 219-228 |
| 38 Lead fields rebalanced across sections | Not individually re-verified field-by-field for this doc — out of scope for the comment-restoration task; take the live org / App Builder as authoritative if a discrepancy is suspected |

### Item 2 — Development Components (Code)

#### Lightning Web Components

| Component | Location | Change |
|-----------|----------|--------|
| `portfolioDealSiblings` | `force-app/main/default/lwc/portfolioDealSiblings/` | Card-tile redesign of the sibling row markup and styling. No Apex change, no wire/payload shape change. |

No new bundles were created, no bundle was renamed, and no Apex class was touched. Placement was not
changed — the bundle remains on both `Lead_Record_Page` and `Opportunity_Record_Page` sidebar
regions, in the same `<itemInstances>` blocks as before.

#### Not touched, and deliberately so

- `PortfolioDealController.cls` / `PortfolioDealSelector.cls` — no Apex change of any kind.
- `c/recentPortfolioDeals` — the sibling "lists deals" card; explicitly out of scope.
- `Lead_Record_Page` / `Opportunity_Record_Page` placement, region, or `componentName` — unchanged.
- The bundle's `masterLabel` and `.js-meta.xml` `<description>` — the description sits at ~210 chars
  against a 255-char cap that only a deploy catches (a known repo trap; see `field: apex identifier
  gotchas / XML comment` memory), so it was deliberately left alone.
- No test classes were created (no Apex was touched); the existing Jest suite for this bundle was
  updated in the same change as the markup (see *Testing* below), not as a separate step.

---

## 🔑 Key Design Decisions and Rationale

Pulled from `agent-output/design-requirements.md` (blocking decisions D1/D2, findings C1-C6) and from
the in-file header comments carried in the deployed component itself.

### D1 — `objectLabel` stayed as visible text; only `status` moved into the badge

The literal brief read as "icon + name + badge replaces the meta line," which would have deleted the
object-label text from the tile entirely. The design pass flagged this (finding C4) before any code
was written: an existing test in this bundle states its purpose as *"a Lead row and an Opportunity
row must be distinguishable to a human WITHOUT the client knowing either object exists"* — the
component is deliberately object-agnostic on the client, and `objectLabel` is the payoff of a
server-side describe (`Lead.SObjectType.getDescribe().getLabel()` /
`Opportunity.SObjectType.getDescribe().getLabel()`, `PortfolioDealController.cls` lines 355-356) done
expressly so the client never derives an object name itself. An icon conveys object type to a sighted
user who already recognizes the iconography, and to nobody else. The chosen shape (D1-a) is therefore
purely additive: `objectLabel` stays as visible text next to the icon; only `status` moves into the
new `lightning-badge`. Every fact the pre-redesign markup made true (a Lead row and an Opportunity
row are distinguishable in words, not just icons) stays true after the redesign — confirmed in the
current template (`portfolioDealSiblings.html` lines 116-129) and pinned by the existing "shows each
row's object label and state" Jest test, whose assertions moved only the status half onto
`badgeLabels()`.

### D2 — the icon is mapped from `objectLabel`, and the generic default is the point, not a tidy-up

`objectLabel` is not a stable literal — it is admin-renameable (a describe-derived tab label) and
locale-translated. The chosen mapping (D2-a) keys **only** off `row.objectLabel`, with a generic
fallback icon (`standard:record`) for any value the map does not recognize:

```js
const ICON_BY_OBJECT_LABEL = new Map([
    ['Lead', 'standard:lead'],
    ['Opportunity', 'standard:opportunity']
]);
const GENERIC_ICON = 'standard:record';
```

Without the fallback, a renamed tab, a translated locale, or a third object added server-side (the
`Transaction__c` precedent cited in the bundle's own header, where a seventh object joined a related
feature with zero client changes) would render a blank or broken icon on every affected row. The
fallback is what preserves the documented "a third object can be added with zero client changes"
property of this component family.

### The `Map`, not an object literal — caught in code review

`ICON_BY_OBJECT_LABEL` is declared as a `Map`, not a plain object literal, because `objectLabel` is an
admin-controlled string that could theoretically equal an `Object.prototype` key. `{Lead: '…'}
['constructor']` resolves the **inherited** `Object.prototype.constructor` — a truthy function — so a
plain-object lookup's `||` fallback would never trigger, and `lightning-icon` would be handed a
function instead of a string. Under the `Map`, `.get('constructor')` is `undefined` like any other
unknown key, and the row correctly falls through to `GENERIC_ICON`.

This was caught and fixed during code review's first pass, together with a gap in the test suite: the
original fixture set (an `UNRECOGNISED_LABEL` case using `'Prospecto'`, standing in for a translated
org) proved the fallback *exists*, but did not distinguish a `Map` from an object literal — `({Lead:
'…'})['Prospecto']` is `undefined` and falls through identically, so a future "simplification" of the
`Map` back to `{}` would have passed that test too. The fix added a second fixture,
`PROTOTYPE_KEY_LABEL` (`objectLabel: 'constructor'`), whose corresponding test
(`__tests__/portfolioDealSiblings.test.js`, "AN OBJECT LABEL THAT IS AN `Object.prototype` KEY STILL
FALLS BACK TO THE GENERIC ICON") is the only one in the suite that actually pins the `Map` choice —
under an object literal it fails with a `[Function]` diff instead of the expected icon string.

### Kept `<ul>/<li>` markup — following an in-repo precedent, not a fresh decision

The design pass identified `c/competingBrokerSubmissions` as direct precedent: it sits in the **same
`sidebar` region of the same `Lead_Record_Page`**, one item above `portfolioDealSiblings` (confirmed
at line 1841 vs the sibling component's placement), and had already solved "card-tile look without
losing list semantics" by styling the `<li>` itself as the tile (`.cbs-tile`, in
`competingBrokerSubmissions.css`). That bundle's own header records that it moved *to* `<ul>/<li>`
*from* a `<table>` specifically to preserve list semantics for screen readers. Rewriting
`portfolioDealSiblings` to a `<div>`-based structure would have been an unforced accessibility
regression against a decision this codebase had already made once. The current template
(`portfolioDealSiblings.html` lines 89-134) keeps `<ul class="pds-list">` / `<li class="pds-item">`,
with the tile's border/radius/padding applied to `.pds-item` directly.

As a direct consequence, `slds-has-dividers_bottom-space` (previously on the `<ul>`) and its companion
`slds-item` class (previously on each `<li>`) were both removed in the same change — bordered tiles
plus SLDS bottom dividers draw a double rule between rows, and `slds-item` carries meaning only as a
child of `slds-has-dividers_*`; left behind alone it becomes dead markup shaped like a divider list,
inviting a future editor to "restore" a look the redesign deliberately removed. The removal is pinned
by a dedicated Jest test ("CARD TILES: one tile per row, and no SLDS dividers doubling up with the
borders").

### Neutral badge only, no color-coding by status/outcome

`status` is the raw `Lead.Status` or `Opportunity.StageName` value (`PortfolioDealController.cls`
line 415-416: *"`Lead.Status` or `Opportunity.StageName` — whichever this row is"*) — both
admin-editable picklists. The component is deliberately built to be object-agnostic on the client (no
schema import, no branching on `objectApiName` anywhere in the bundle), which is what lets one LWC
bundle serve both the Lead and Opportunity record pages. Color-coding the badge by outcome would have
required the client to interpret object-specific vocabulary it is deliberately kept blind to, and
would be fragile against any admin-renamed stage/status value. The badge is rendered with no
`variant` and no conditional class — one neutral treatment for every row, on every object.

### Code review cycle — two non-behavioral warnings, both fixed before deployment

Initial code review verdict was **APPROVED WITH WARNINGS**:

1. **An inaccurate CSS-specificity explanation in a code comment.** An earlier version of the HTML
   template's comment on the removed `slds-item` class argued that a leftover global SLDS rule would
   have won a cascade fight against `.pds-item`'s own `display: flex`, depending on stylesheet load
   order. This was factually wrong — LWC's style compiler scopes every selector in the bundle with a
   scoping attribute, so `.pds-item` compiles to roughly
   `.pds-item[c-portfolioDealSiblings_portfolioDealSiblings]` (specificity `(0,2,0)`), which beats a
   global `.slds-item` rule's `(0,1,0)` regardless of load order, and under native shadow DOM the
   global rule would not cross the shadow boundary to begin with — there was never a cascade fight to
   lose. The comment was corrected in place (`portfolioDealSiblings.html` lines 77-87: *"THIS IS NOT
   A CSS-SPECIFICITY OR LOAD-ORDER ARGUMENT... do not re-derive it"*) to state the real reasons
   (nothing accessibility-related was ever attached to `slds-item`; no other bundle under `force-app/`
   uses the class; the removal is pinned by a Jest assertion) and to warn a future reader not to
   re-derive the wrong explanation.
2. **A test that didn't actually pin the `Map`-vs-object-literal decision.** Covered above under *The
   `Map`, not an object literal*.

Both fixes were re-verified before deployment:
- SLDS linter — clean.
- Bundle Jest suite — 15/15 passing (`portfolioDealSiblings.test.js`).
- Full repo Jest suite — 785/786 passing, with the one failure confirmed pre-existing and unrelated
  (a different, untouched bundle) — reported by the code review pass, not independently re-run by
  this documentation agent, which has no test-execution tooling.

---

## 📁 File Locations

| Component | Path |
|-----------|------|
| Lead record page (Item 1 — comment restored) | `force-app/main/default/flexipages/Lead_Record_Page.flexipage-meta.xml` (lines 812-824) |
| Opportunity record page (Item 2 placement, unchanged) | `force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml` (sidebar region, line 1841; placement block lines 1808-1826) |
| `portfolioDealSiblings` component bundle (Item 2) | `force-app/main/default/lwc/portfolioDealSiblings/` |
| — markup | `force-app/main/default/lwc/portfolioDealSiblings/portfolioDealSiblings.html` |
| — styling | `force-app/main/default/lwc/portfolioDealSiblings/portfolioDealSiblings.css` |
| — controller | `force-app/main/default/lwc/portfolioDealSiblings/portfolioDealSiblings.js` |
| — metadata | `force-app/main/default/lwc/portfolioDealSiblings/portfolioDealSiblings.js-meta.xml` |
| — Jest suite | `force-app/main/default/lwc/portfolioDealSiblings/__tests__/portfolioDealSiblings.test.js` |
| Apex DTO/controller (unchanged, cited for `status`/`objectLabel` provenance) | `force-app/main/default/classes/PortfolioDealController.cls` (`SiblingRow` class, lines 410-424; `LEAD_LABEL`/`OPPORTUNITY_LABEL`, lines 355-356) |
| In-repo precedent for the card-tile pattern | `force-app/main/default/lwc/competingBrokerSubmissions/` (`.html`, `.css`, `__tests__/`) |
| Design requirements (source of D1/D2 and C1-C6) | `agent-output/design-requirements.md` |

---

## ⚙️ Configuration Details

### `ICON_BY_OBJECT_LABEL` map (`portfolioDealSiblings.js`)

```js
const ICON_BY_OBJECT_LABEL = new Map([
    ['Lead', 'standard:lead'],
    ['Opportunity', 'standard:opportunity']
]);
const GENERIC_ICON = 'standard:record';
```

Keyed **only** on `row.objectLabel` (a server-supplied describe label). No schema import, no branch
on `objectApiName` anywhere in the bundle.

### Row derivation (`portfolioDealSiblings.js`, `get rows()`)

```js
get rows() {
    return this.siblings.map((row) => ({
        ...row,
        iconName: ICON_BY_OBJECT_LABEL.get(row.objectLabel) || GENERIC_ICON
    }));
}
```

Every server field is spread through untouched; `iconName` is the one derived display value the
template needs. Derivation happens here, not in the `@wire` handler, so the wire handler stays a pure
server-payload-to-field mapping.

### Tile markup shape (`portfolioDealSiblings.html`, per row)

```html
<li key={row.id} class="pds-item">
    <lightning-icon icon-name={row.iconName} size="x-small" class="pds-icon"></lightning-icon>
    <div class="pds-body">
        <a href={row.recordUrl} data-id={row.id} onclick={handleSiblingClick} class="pds-link">{row.name}</a>
        <span class="slds-text-body_small slds-text-color_weak pds-meta">
            <span class="pds-object">{row.objectLabel}</span>
            <lightning-badge label={row.status} class="pds-badge"></lightning-badge>
        </span>
    </div>
</li>
```

The icon carries no `alternative-text` (decorative only — `objectLabel` remains the accessible text).

### CSS anti-overflow rules (`portfolioDealSiblings.css`)

Four load-bearing declarations, all necessary to keep the tile from bursting the ~360px sidebar with
the new badge content:

1. `min-width: 0` on every flex item holding text (`.pds-item`, `.pds-body`, `.pds-link`, `.pds-meta`).
2. `overflow-wrap: anywhere` on `:host` (inherits across the shadow boundary into
   `lightning-badge`'s own shadow root — the only lever this stylesheet has over the badge's
   internals).
3. `flex-wrap: wrap` on `.pds-item` and `.pds-meta`, so a long status wraps below the object label.
4. No fixed pixel widths, no `overflow-x`, no `nowrap`, no media queries (the constraint is
   **container** width, not viewport — the same sidebar region renders at ~360px or the main region
   at ~900px depending on layout).

All `var(--slds-g-*, ...)` tokens are paired with a hex fallback, per the file's own stated house
convention (matching `.cbs-tile` in `competingBrokerSubmissions.css`).

---

## 🔄 Data Flow

### Item 1 — comment restoration

```
User edits Lead_Record_Page in App Builder (section renames, field rebalance,
Broker_First__c/DPEG_First__c removal, Broker tab deletion, Disqualification_Reason__c visibility rule)
        │
        ▼
Metadata retrieved into repo — retrieve UNIONS/reflects live org state but STRIPS all XML comments
        │
        ▼
13-line comment documenting the packageSiblings → portfolioDealSiblings rename hazard is lost
        │
        ▼  (this task)
Comment restored verbatim at its original location — no functional change, no redeploy required
for behavior (comments have zero runtime effect)
```

### Item 2 — sibling row rendering

```
@wire(getSiblingRecords, { recordId }) → PortfolioDealController.getSiblingRecords(Id)
        │
        ▼
data.siblings: List<SiblingRow> { id, name, objectLabel, recordUrl, status }
        │
        ▼
get rows() — spreads each row, adds iconName = ICON_BY_OBJECT_LABEL.get(objectLabel) || GENERIC_ICON
        │
        ▼
Template: <li class="pds-item"> per row
    ├─ <lightning-icon icon-name={row.iconName}>      (decorative)
    ├─ <a class="pds-link" href={row.recordUrl}>       (unchanged link/nav behavior)
    ├─ <span class="pds-object">{row.objectLabel}</span>  (unchanged text, kept per D1)
    └─ <lightning-badge label={row.status}>            (NEW — replaces the old inline "· {status}" text)
```

No change to the wire call, the Apex method, the DTO shape, or the click/navigation handlers.

---

## 🧪 Testing

### Item 1

Not applicable — an XML comment has no effect on Apex or LWC test suites and requires no test
coverage.

### Item 2

| Suite | Result |
|-------|--------|
| SLDS linter | Clean |
| `portfolioDealSiblings` bundle Jest suite | 15/15 passing |
| Full repo Jest suite | 785/786 passing; the 1 failure confirmed pre-existing, in a different, untouched bundle, and unrelated to this change |

Key test scenarios in `__tests__/portfolioDealSiblings.test.js` relevant to this redesign:

- **CARD TILES** — one `<li class="pds-item">` tile per row; `.pds-list` no longer carries
  `slds-has-dividers`; tiles no longer carry `slds-item`.
- **ICONS** — each row's icon matches its mapped `objectLabel` (`standard:lead` / `standard:opportunity`).
- **ICONS: unrecognised label** — an unmapped `objectLabel` (`'Prospecto'`) falls back to
  `standard:record`, and the row's text (label + status) remains fully readable.
- **ICONS: `Object.prototype` key label** — `objectLabel: 'constructor'` still falls back to
  `standard:record` (a plain object-literal lookup would instead resolve a function) — the test that
  specifically pins the `Map` choice over an object literal.
- **Object label + status, both server-supplied** — updated to assert `objectLabel` from `.pds-meta`
  text and `status` from the badge's `label` property (the sfdx-lwc-jest `lightning-badge` stub
  renders an empty template, so status is not in `textContent`).
- The "renders nothing at all" test (no portfolio deal) and both `toBeAccessible()` tests (data
  branch and error branch) were left untouched, per the suite's own header, which calls the
  "renders nothing" test the most important one in the file.

No `salesforce-unit-testing` agent invocation was required — no Apex was created or changed.

### Deliberately not covered by the automated suite

jsdom performs no layout, so `scrollWidth`/`clientWidth` are both `0` in Jest — no assertion in this
file can prove the tiles do not burst the ~360px sidebar. This is a documented, accepted gap (see
*Notes & Considerations* below), not an oversight.

---

## 🔒 Security

No permission sets, sharing rules, profile changes, FLS grants, or Apex were part of either item.
Item 2 makes no wire/payload/Apex changes, so no new field access is required beyond what the
existing `PortfolioDealController.getSiblingRecords` call already needed. `PortfolioDealController`
remains `with sharing`; no change to its access model.

---

## 📝 Notes & Considerations

### Still-open manual acceptance step (Item 2)

jsdom cannot measure CSS layout or overflow, so the automated suite cannot prove the badge does not
burst the sidebar. **A manual check in the live org is still required**: open a Lead and an
Opportunity belonging to a multi-property portfolio deal and visually confirm no horizontal scroll in
the ~360px sidebar with a long property name and a long status value. This is called out explicitly
in the component's own CSS header (`portfolioDealSiblings.css` lines 42-46) as the only verification
method available for this class of layout risk in this codebase — the same acceptance gap the
in-repo precedent (`competingBrokerSubmissions`) also carries and resolves the same way.

### Known limitation — comments do not survive a future retrieve

The 13-line comment restored in Item 1 will be **stripped again** by any future `sf project retrieve`
against this file, because the Salesforce Metadata API does not persist XML comments. This is a
standing, accepted limitation of the retrieve workflow in this repo, not a defect introduced by this
change — anyone retrieving `Lead_Record_Page` after a live App Builder edit should expect to re-apply
this comment (or move the warning to a location that survives retrieve, e.g. this documentation file
or `ARCHITECTURE.md`, if repeated loss becomes a recurring cost).

### Deferred / explicitly out of scope

| Item | Status |
|---|---|
| Field-by-field verification of the 38 rebalanced Lead fields across the renamed sections | Not individually re-verified for this doc; App Builder / live org is authoritative if a discrepancy is suspected |
| `role="list"` / `aria-label` annotation on the `<ul>` (design decision D3) | Not included — explicitly declined by the user this round; flagged in the design doc as a reasonable future addition |
| CSS source-text anti-regression test (design decision D4) | Not included — not requested |
| A `<span class="slds-assistive-text">Status:</span>` prefix before the badge (present in the `competingBrokerSubmissions` precedent) | Considered and not copied — the pre-redesign markup carried no such prefix, so adding one would be new behavior, not parity |
| Data cleanup / re-verification of any Lead currently affected by the Disqualification_Reason__c visibility rule change | Out of scope — App Builder change, not authored by this task |

### Dependencies

- Item 2 depends on `PortfolioDealController.SiblingRow.status` continuing to carry the raw
  `Lead.Status` / `Opportunity.StageName` value — if that DTO field's meaning or type changes, the
  badge's `label` binding and the icon-fallback tests would need review.
- Item 2's icon mapping depends on `objectLabel` continuing to be produced by
  `SObjectType.getDescribe().getLabel()` (admin-renameable, translated) rather than a hardcoded
  literal — this is precisely why the generic fallback and the `Map` (not object-literal) choice are
  load-bearing, not optional hardening.
- Item 1's comment references `ARCHITECTURE.md section 5`'s "one bundle, not one per object"
  precedent — if that section is renumbered or reworded, the comment's citation would go stale (not
  functionally broken, just a dangling reference for a future reader).

---

## ARCHITECTURE.md Update

**No edit was made to `ARCHITECTURE.md`.** Neither item touches any of ARCHITECTURE.md's stated
triggers for a mandatory update (no custom object added, no new Apex service introduced, no
integration boundary touched). Item 1 is a documentation-only XML comment restoration with zero
deployable effect. Item 2 is a single existing LWC bundle's markup/CSS/JS restyle — no new component,
no new Apex, no schema change, and the object-agnostic "one bundle serves both record pages" pattern
this component follows is not new; it is the same pattern already described in ARCHITECTURE.md §5 and
in the bundle's own header comments, which this redesign did not alter.

---

## 📜 Change History

| Date | Author | Change Description |
|------|--------|--------------------|
| 2026-08-19 | Documentation Agent | Initial creation, documenting the `Lead_Record_Page` comment restoration (Item 1) and the `portfolioDealSiblings` card-tile redesign including its code review cycle (Item 2), both completed prior to this pass. |
