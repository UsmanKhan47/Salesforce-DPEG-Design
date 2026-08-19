# DESIGN REQUIREMENTS — `Property_Address__c` on the `portfolioDealSiblings` tiles

Date: 2026-08-19
Scope: additive display field on `c/portfolioDealSiblings`. Touches Apex (selector + controller DTO),
LWC markup/CSS, Apex tests, Jest.

> Supersedes the previous contents of this file (the 2026-08-19 card-tile redesign, now deployed).
> That design's binding decisions — D1-a "`objectLabel` stays as visible text" and D2-a "icon maps
> from `objectLabel` with a generic default" — are permanently recorded in
> `portfolioDealSiblings.js` (header lines 117-162) and are treated as constraints below, not as
> history to re-open.

---

## 0. PREMISES CHECKED AGAINST THE REPO

The brief's five verified facts were re-measured. **All five are correct as stated.**

| Brief's claim | Verified |
|---|---|
| `Lead.Property_Address__c` is plain Text, nullable | ✅ `Lead/fields/Property_Address__c.field-meta.xml` — `<type>Text</type>`, `<length>255</length>`, `<required>false</required>` |
| `Opportunity.Property_Address__c` is a read-only formula on `Property__r.Address__c`, blank when `Property__c` is empty | ✅ `Opportunity/fields/Property_Address__c.field-meta.xml` — `<formula>Property__r.Address__c</formula>`, `<formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>`. `Opportunity.Property__c` exists. |
| Data flow selector → `buildSiblings()` → `SiblingRow` → `rows` getter → HTML | ✅ `PortfolioDealSelector.selectWithMembersById` (lines 143-159) → `PortfolioDealController.buildSiblings` (329-349) → `SiblingRow` (410-425) → `portfolioDealSiblings.js` `rows` (271-276) → `.html` (89-134) |
| `Property_Address__c` is in neither subquery nor the DTO | ✅ Subqueries select `Id, Name, Status` and `Id, Name, StageName` only (lines 149-152); `SiblingRow` has `id / name / objectLabel / recordUrl / status` only |
| Requires extending SOQL and DTO, not just the LWC | ✅ Confirmed — with one refinement below (F3: **no `.js` change is needed**) |

### Findings the brief did not have — read F1 before approving

**F1 — 🔴 THIS IS AN FLS CHANGE, NOT A GOVERNOR-LIMIT QUESTION, AND IT BREAKS THE CARD FOR TWO PERSONAS AS WRITTEN.**

The brief asks to "confirm this doesn't push the query over any documented governor concern." It does
not: one extra Text field per child row adds no query, no row and no meaningful heap. **But the
concern this selector actually documents is a different one, and this change walks straight into it.**
`PortfolioDealSelector` warns at `selectRecent` (lines 198-201):

> *"MEMBER `Id` ONLY, NEVER `Name` / `Status` / `StageName`. The widget shows COUNTS, not rows, and
> this query is `WITH USER_MODE`: **every field added here becomes a field whose FLS can throw and
> blank the whole card.** Selecting a name 'in case the widget wants it later' is how a homepage
> acquires a new single point of failure for free."*

`selectWithMembersById` is `WITH USER_MODE` (line 155) and its own `@throws` says so (lines 137-139).
`USER_MODE` throws; it does not degrade. `PortfolioDealController.getSiblingRecords` catches
everything (line 228) and rethrows `READ_FAILURE_MESSAGE`, so the LWC renders its **red `.lv-error`
banner** — on every Lead and Opportunity record page that has a portfolio deal.

Today the query's only permissionable custom field is `Portfolio_Deal__c.Property_Count__c`
(`Portfolio_Deal__c.Name` needs no grant — custom Name fields are `permissionable=false`, stated in
three permission-set headers). `Lead.Status`, `Opportunity.StageName` and `Lead.Name` are standard
fields that are always readable. So **four** permission sets can run this query today. Cross-referencing
that against who holds the two new fields:

| Permission set | `Portfolio_Deal__c.Property_Count__c` (runs the query today) | `Lead.Property_Address__c` | `Opportunity.Property_Address__c` | Result after this change |
|---|---|---|---|---|
| `DPEG_Acquisition_View` | ✅ (1702) | ✅ (546) | ✅ (1242) | ✅ safe |
| `DPEG_Acquisition_Edit` | ✅ (1291) | ✅ (731) | ✅ (1196) | ✅ safe |
| `Broker_Protection_Access` | ✅ (587) | ✅ (398) | ❌ **absent** | 🔴 **breaks** |
| `DPEG_Admin_Access` | ✅ (408) | ❌ **absent** | ❌ **absent** | 🔴 **breaks** |

Both real personas are covered — `DPEG_Principal_PSG` includes `DPEG_Acquisition_View` (line 21) and
`DPEG_Junior_Analyst_PSG` includes `DPEG_Acquisition_Edit` (line 39). Neither `DPEG_Admin_Access` nor
`Broker_Protection_Access` belongs to any permission set group; both are assigned directly.

The `DPEG_Admin_Access` case is the one this repo has paid for before — its own header (lines 10-14)
says it outright: *"Metadata-API-deployed custom fields arrive with NO field permissions for ANY
profile, System Administrator included — a trap this repo has already paid for … where a bare admin
threw on the very field they had just deployed."* `profiles/**` is `.forceignore`d, so `DPEG_Admin_Access`
is the only thing standing in for the Admin profile. **A System Administrator would open a Lead and see
a red error where a working card used to be.** This is a decision the user has to make (D1) because it
is admin work and a privilege change, neither of which was requested.

**F2 — the Opportunity field is a FORMULA, which changes how the Apex tests must be written.** Three
consequences the test brief has to carry, or the unit-testing agent will hit them one at a time:
1. `opp.Property_Address__c = '...'` **does not compile** — a formula field is not writable. The test
   must create a `Property__c` (`TestDataFactory.createProperties` already sets `Address__c`, line 1158)
   and set `Opportunity.Property__c` to it. `TestDataFactory.createOpportunities` has no `Property__c`
   overload (lines 649, 671), so the lookup is set inline in the test.
2. **The value only exists after a re-query.** Formula fields are computed at query time, so the
   in-memory `Opportunity` returned by the factory has `Property_Address__c == null` no matter what.
   An assertion against the pre-insert sObject is vacuously wrong.
3. **The Opportunity null case is free and the Lead null case is not.** An Opportunity with no
   `Property__c` yields a blank formula automatically; `TestDataFactory.createLeads` *always* populates
   `Property_Address__c` (line 616), so a Lead null case must null it explicitly.

**F3 — no `portfolioDealSiblings.js` change is required, and that is by design.** The brief lists the
LWC as one change; it is really two files, not three. The `rows` getter already spreads the row
(lines 271-276) and its own comment states the reason (269-270): *"The spread keeps this
forward-compatible: a field added to the Apex DTO reaches the template without an edit here."* This
change is the first exercise of that property. Adding a `propertyAddress` passthrough to the getter
would be redundant code that the header explicitly anticipated not needing.

**F4 — this is genuinely additive, so unlike the last round there is no accessibility decision hiding
in it.** The previous design's C4/D1 problem was that icon+badge *deleted* `objectLabel` from the
accessible name. Nothing is removed here: the name link, `objectLabel` and the status badge all stay
exactly as they are. The existing test asserting Lead/Opportunity rows stay distinguishable is
unaffected. Flagged so review does not go looking for a deletion that is not there.

**F5 — pre-existing, explicitly OUT OF SCOPE: `DPEG_Opportunity_View` grants
`Opportunity.Property_Address__c` (line 355) but not `Portfolio_Deal__c.Property_Count__c`,** so a
holder of only that set already cannot run this query and already sees the error banner. That is not
caused by this change and must not be "fixed" inside it. Noted only so nobody attributes it to this work.

**F6 — no new data disclosure.** `Opportunity.Property_Address__c` is a cross-object formula, and
cross-object formulas are evaluated without the running user's sharing on `Property__c` (which is
Private OWD). That sounds like a new leak but is not: the address is already on the Opportunity's own
compact layout (`Deal_Highlights`) and record page, and this card only ever shows rows for
Opportunities the user can already see and click into. The tile surfaces nothing a single click did
not already surface.

---

## 1. BLOCKING DECISION

One question. Everything else in the brief is specified.

**D1 — Do the two FLS gaps in F1 get closed, and is `Broker_Protection_Access` allowed to read an
Opportunity field?**

- **D1-a (recommended): grant both fields in `DPEG_Admin_Access`, and grant
  `Opportunity.Property_Address__c` in `Broker_Protection_Access`.** Four `<fieldPermissions>` blocks
  total, all `readable=true` / `editable=false` (both fields are read-only in this context, and the
  Opportunity one is a formula and *cannot* be editable). Restores parity: every persona that can see
  the card today still sees it.
- **D1-b: grant in `DPEG_Admin_Access` only.** Accepts that `Broker_Protection_Access`-only holders
  lose the card entirely. Choose this only if that set is deliberately Lead-scoped and no human is
  assigned it alone.
- **D1-c: ship no permission-set change.** The card breaks for administrators. Not recommended, and
  it would land as a production defect rather than a known trade-off.

⚠ **Whichever is chosen, two constraints are non-negotiable on the permission-set edit** (both are
written into `DPEG_Admin_Access`'s own header, lines 38-48):
- **A `PermissionSet` deploy REPLACES that file's entire `<fieldPermissions>` set.** The edit must be a
  surgical insertion diffed against `HEAD`, never a regeneration, or unrelated org-side grants are
  silently wiped.
- **FLS truth lives in the org, not this repo** (`profiles/**` is force-ignored). The post-deploy check
  is to open a Lead *as an administrator* and confirm the card renders — not to trust a green deploy.

🔴 **And one trap to name up front, because it is the likely wrong turn:** a developer or test author
who hits `System.QueryException: No such column 'Property_Address__c'` will be tempted to switch
`selectWithMembersById` to `WITH SYSTEM_MODE`. **That is forbidden here.** The selector's class header
(lines 30-47) is an explicit, argued ban — *"MODE — `WITH USER_MODE`, DELIBERATELY. DO NOT 'CORRECT'
THIS TOWARD SYSTEM_MODE"* — and it pre-rebuts both of the usual justifications for this exact path.
The correct fix for that exception is a permission set. Every time.

---

## 2. WHAT THE USER REQUESTED

Show `Property_Address__c` as additional visible text on each sibling tile in
`c/portfolioDealSiblings`, alongside the existing record-name link. Purely additive — the name link is
unchanged and stays the primary clickable text — so an analyst can read the property address without
opening each sibling record. Requires extending the SOQL subqueries and the `SiblingRow` DTO, plus
Apex test and Jest coverage including the null case.

---

## 3. ADMIN WORK (salesforce-admin)

**Conditional on D1.** No new fields, objects, layouts or flexipages — both fields already exist.

- **If D1-a:** add to `DPEG_Admin_Access` — `Lead.Property_Address__c` and
  `Opportunity.Property_Address__c`, both `readable=true` / `editable=false`. Add to
  `Broker_Protection_Access` — `Opportunity.Property_Address__c`, `readable=true` / `editable=false`.
  Record the reason in each file's in-root XML comment (the established pattern in both files), citing
  `PortfolioDealSelector.selectWithMembersById` as the consumer — five permission-set headers already
  cite selector methods by name for exactly this purpose.
- **If D1-b:** the `DPEG_Admin_Access` half only.
- **If D1-c:** no admin work.

⚠ Surgical insertion, diffed against `HEAD`. See the two constraints under D1.

---

## 4. DEVELOPMENT WORK (salesforce-developer)

Small, well-bounded change across four files. Not integration, not LDV, not architectural →
`salesforce-developer`, not `salesforce-technical-architect`.

- **`PortfolioDealSelector.cls`** — add `Property_Address__c` to both subquery SELECT lists in
  `selectWithMembersById` (lines 149-152). `WITH USER_MODE` stays (see the ban above). `selectRecent`
  is **not** touched — its header forbids selecting member display fields, and this feature has no use
  for them there. Extend the method's Javadoc to record that the FLS surface of this query grew by two
  fields and which permission sets carry them.
- **`PortfolioDealController.cls`** — add `@AuraEnabled public String propertyAddress;` to `SiblingRow`,
  add the constructor parameter, and pass `l.Property_Address__c` / `o.Property_Address__c` from
  `buildSiblings` (lines 335-336, 343-344). Document on the DTO member that the two sides are **not the
  same kind of field** — Lead's is stored Text from LLM extraction, Opportunity's is a formula through
  `Property__c` that is blank until the lookup is set — because that asymmetry is what makes "null is
  normal" true on both objects for different reasons.
- **`portfolioDealSiblings.html`** — insert one gated element inside `.pds-body`, **between** the
  `.pds-link` anchor and the `.pds-meta` span:

  ```html
  <template if:true={row.propertyAddress}>
      <span class="slds-text-body_small slds-text-color_weak pds-address">{row.propertyAddress}</span>
  </template>
  ```

  The `if:true` gate is what satisfies "no empty line, no `null` text" — a null, undefined or empty
  address renders no element at all, not an empty one. Use `if:true` for consistency with the rest of
  this file (`lwc:if` is the modern form, but converting the bundle's other four directives is out of
  scope). **Order rationale:** name (primary, clickable) → address (the new at-a-glance datum,
  subordinate to the name) → `objectLabel` + status badge (metadata). Top-down by importance, and it
  leaves the badge row last, which is where the existing wrap handling already lives.
- **`portfolioDealSiblings.css`** — `.pds-address { min-width: 0; }` and nothing more. `.pds-body` is
  already `flex-direction: column` with a `gap` (lines 89-95), so a third child stacks with correct
  spacing for free, and `overflow-wrap: anywhere` is inherited from `:host` (rule 2, lines 30-35). **Do
  not add** a fixed width, `nowrap`, `overflow-x`, a media query, or a new `overflow-wrap` declaration —
  all four are named as forbidden in that file's header, and `min-width: 0` on the new flex text child
  is precisely rule 1. Add the new class to the header's rule-1 list of flex items that hold text.
- **`portfolioDealSiblings.js`** — **no change.** See F3.
- **Headers** — record the addition and the F1 FLS consequence in the `.js` class header and the
  selector's method Javadoc. This repo treats headers as authoritative decision history, and "adding a
  field to this query can break the card for a persona" is exactly the fact the next editor needs.

**Two traps to name to the developer:**
1. **Do not add `title={row.propertyAddress}`** (or any getter-bound attribute) to an ungated element.
   A getter bound to a custom element's attribute is written *unconditionally*, so a null address
   renders a literal `title="undefined"` in the DOM. Gating with `if:true` as specified avoids it; a
   "helpful" tooltip added later on `.pds-item` would reintroduce it.
2. **Do not edit `.js-meta.xml`** — its `<description>` is ~210 chars against a **255-char cap that
   only a deploy catches** (Jest, the SLDS linter and code review all pass a 258-char one).

**Explicitly out of scope:** the name/link text (`row.name` stays the primary clickable text,
untouched); the fallback chain to `Property_Name__c` / `Property__r.Name` (the user simplified the ask
to this one field); `Lead_Record_Page.flexipage-meta.xml`; `Opportunity_Record_Page.flexipage-meta.xml`;
`c/recentPortfolioDeals`; `PortfolioDealSelector.selectRecent`; the `RecentPortfolioDealRow` DTO; the
`.js-meta.xml` `masterLabel` and `<description>`.

---

## 5. TEST WORK (salesforce-unit-testing, after the developer)

- **`PortfolioDealSelectorTest`** — assert `Property_Address__c` comes back populated on a Lead member
  and on an Opportunity member, and blank on each when unset. **Per F2**, the Opportunity case needs a
  real `Property__c` with `Address__c` set (`TestDataFactory.createProperties`), `Opportunity.Property__c`
  pointed at it, and **the assertion made against the re-queried record** — the formula does not exist
  on the in-memory sObject. The Opportunity null case is an Opportunity with no `Property__c`; the Lead
  null case must null `Property_Address__c` explicitly, because the factory always populates it.
- **`PortfolioDealControllerTest`** — assert `SiblingRow.propertyAddress` is carried through for both
  member types and is null-safe when the source field is blank, from both a Lead anchor and an
  Opportunity anchor (the existing exclusion tests already run both directions).
- **Bulk volume:** `.claude/rules/bulk-test-rule.md`'s 251-record mandate **does not apply** — these are
  selector reads and a pure mapping method, with no trigger batch to force a second firing and no DML
  in the method under test. Match the existing tests' volume; do not inflate.
- Do **not** add FLS/`runAs` permission-set tests unless the user asks — the F1 gaps are closed by
  metadata and verified in the org (see D1's post-deploy check), not by a test.

---

## 6. JEST WORK (in the developer's change, per the previous round's precedent)

- Add `propertyAddress` to the `WITH_SIBLINGS` fixture's two rows (test lines 96-109) with realistic
  values, and to the `Prospecto` (144-150) and `constructor` (173-179) fixtures so all fixtures stay
  shaped like the real payload.
- Add a **null-address case** — a fixture row with `propertyAddress: null` — asserting that **no
  `.pds-address` element is rendered** for that row (not that it renders empty). Assert on the rendered
  DOM, not on a getter.
- Assert the address text renders for a populated row, and that the `.pds-link` name text is
  **unchanged** — that is the "purely additive" claim, and it is the one thing the suite can actually
  falsify.
- Keep both `toBeAccessible()` tests, keep the "renders nothing" test first and untouched, and leave
  the unrecognised-label / generic-icon test alone (its header calls it the only falsifier for a
  failure a green run otherwise hides).

⚠ **jsdom performs no layout**, so no Jest test can prove the address does not burst the ~360px
sidebar. `scrollWidth` and `clientWidth` are both `0` there, which makes the obvious assertion `0 <= 0`
and vacuously green. That check is by eye, in the org — see §8.

---

## 7. EXECUTION ORDER

1. **D1 answered** — it determines whether there is admin work at all.
2. `salesforce-admin` — the permission-set grants (if D1-a or D1-b). **Before** the Apex deploys, so
   the widened query never runs against an org that cannot satisfy it.
3. `salesforce-developer` — selector + controller + HTML + CSS + Jest, one change.
4. `salesforce-unit-testing` — the two Apex test classes.
5. `salesforce-code-review` — mandatory; both Apex and LWC changed.
6. `salesforce-devops` + `salesforce-documentation` in parallel, after review passes.

⚠ **Steps 2 and 3 must deploy together or 2 first.** The Apex and the FLS are one atomic change in
effect: deploying the widened `SELECT` to an org whose permission sets have not caught up turns the
card into a red error banner for the affected personas.

---

## 8. ACCEPTANCE BEYOND A GREEN SUITE

1. Open a Lead **and** an Opportunity on a multi-property portfolio deal; confirm the address renders
   under the name on each tile, with the name link, object label and status badge all unchanged.
2. Confirm a sibling with **no** address renders no blank line and no `null` text.
3. Confirm **no horizontal scroll** in the ~360px sidebar with a long address and a long stage value.
   jsdom cannot observe this; it is the standing acceptance step for this bundle.
4. **Do step 1 as a System Administrator specifically** — that is the F1 case, and the one an
   analyst-only smoke test will never catch.

---

## 9. NOT INCLUDED (would be scope creep — say the word if you want any of them)

- Any fallback when `propertyAddress` is null (`Property_Name__c`, `Property__r.Name`, an em dash, an
  "Address not set" placeholder). The gate renders nothing, as requested.
- A label or `slds-assistive-text` prefix on the address line.
- Truncation or `-webkit-line-clamp` on a long address. Current behaviour is to wrap, matching this
  bundle's documented discipline that the card gives way, not the text. Realistic values
  (`"1002 Multi St, Houston, TX"`) wrap to one or two lines; flagged only because the Lead field
  allows 255 characters. Verify by eye in step 3 above and raise it then if it reads badly.
- A `title` tooltip on the address (see the trap in §4).
- Adding the address to `c/recentPortfolioDeals` or to `selectRecent`.
- Closing the pre-existing `DPEG_Opportunity_View` gap in F5.
