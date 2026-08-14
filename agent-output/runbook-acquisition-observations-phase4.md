# Deploy Runbook — Acquisition Observations, Phase 4 (declarative + gates)

**Author:** salesforce-solution-architect · **Date:** 2026-08-14
**Target org:** `usman-dpeg` (`usman.khan.dpeg@avanzasolutions.com`, `00Diw000000Fqw1EAC`)
**Source:** `docs/superpowers/specs/2026-08-14-acquisition-app-observations-design.md` §5,
`agent-output/design-requirements-acquisition-observations.md` §3 (Phase 4) / §4 (Phase 4) / §7 / §8 / §9 C10 / §9 C11

**NOTHING IN THIS PACK HAS BEEN DEPLOYED.** Every step below is pending.

Phase 4 was the only phase without a runbook. Its declarative work had been routing through the
requirements document, which is the wrong home for it: Phase 4 is the phase that **introduces a
scheduled job**, and it is the phase whose gates fail with **no trace at all**. Phases 1–3 each fail
loudly somewhere — a red suite, a blocked analyst, a stranded row on a status a human can list.
Phase 4's characteristic failure is **silence that is indistinguishable from success**, four separate
times over (**P4-G1, P4-G2, P4-G4, P4-G6**). That is what this document exists to prevent.

> 🔴 **GATE LABELS IN THIS DOCUMENT ARE PREFIXED `P4-` AND THAT PREFIX IS LOAD-BEARING, NOT
> DECORATION (added 2026-08-14).** Two documents number gates `G1…Gn` and **they agree only through
> G3**: this runbook's §4, and
> `agent-output/design-requirements-acquisition-observations.md` §8. From G4 they diverge — this
> runbook's G4 was the notification type, requirements §8's G4 is the permission-set reconciliation;
> this runbook's G6 was the FlexiPage read-back, requirements §8's G6 is the render probe. An
> operator cross-referencing a bare "G6" between the two lands on **the wrong gate**, in a pack whose
> entire safety story is "follow the gates". Every local gate here is therefore **`P4-G1…P4-G7`**,
> and every reference to a gate in the other document names it explicitly as **requirements §8 Gn**.
> ⚠ **The other three runbooks are NOT all in this state — see §6.1 before assuming.** Phases 1 and 2
> number their gates *inside* requirements §8's space and do not collide; **Phase 3 has the same
> divergent local space this section fixes and has deliberately NOT been renumbered by this build.**

---

## 0. Decisions applied, and what this build did

| # | Decision | Where it came from |
|---|---|---|
| 1 | 🔴 **C11 — the call-for-offers table goes on the `Lead_Funnel` tab, NOT on a new home page.** USER DECISION. The Acquisition app has no home page (no `HomePage` FlexiPage anywhere in `force-app`, no `standard-home` tab in `Acquisition.app`), and creating one would change every acquisitions user's landing surface. | requirements §9 C11, escalated and settled |
| 2 | 🔴 **`Acquisition.app-meta.xml` IS NOT EDITED.** Not by this build, not at any deploy step. That is the entire point of decision 1 — the moment the app file is touched, the cost C11 was avoiding is paid. | decision 1's consequence |
| 3 | 🔴 **The existing `Acquisition` queue STAYS the alert recipient**, with its membership fixed post-deploy rather than a new recipient built. USER DECISION. Safe **only if §4 P4-G2 is actually run.** | requirements §8 G2 (the same gate under the other document's label — the two spaces agree at G2; see the label box in the introduction) |
| 4 | **The notification type is REUSED, not created.** `Acquisitions_Deal_Update` — verified present in the org today, see §3 P4-B. | requirements §3 (Phase 4) |
| 5 | **O2 — scheduled Apex, not a scheduled-triggered Flow.** A Flow cannot satisfy the 251-record rule (it exposes no counter an Apex test can read) and would be a **third** derivation of the urgency ladder the spec exists to unify. | requirements §1 O2 |
| 6 | Do not deploy from this build. Metadata and documentation only. | brief |

**What this build produced:** two FlexiPage edits and one repaired generator. Everything else in
Phase 4 — three fields, seven Apex classes, two LWC bundles, four permission sets — was already on
disk and verified (211 Apex tests / 0 failures, coverage 95–100%, Jest 99 suites / 665 tests).

---

## 1. Current repo state — what THIS build changed

| File | Change |
|---|---|
| `force-app/main/default/flexipages/Lead_Funnel.flexipage-meta.xml` | **+ `c/callForOffersList`** in `region1`, appended after `pipelineStageBoard`. Identifier `callForOffersListComponent`. |
| `force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml` | **+ `c/callForOffersPanel`** in the `sidebar` region, immediately **above** the tabset that holds the Activity tab. Identifier `callForOffersPanelComponent`. |
| `agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js` | **REPAIRED.** It passed against the Phase 4 tree while emitting a wrong copy. See §2. |

Nothing else was touched. In particular this build did **not** enter
`objects/{LOI__c,Contract_Review__c}/**`, `pathAssistants/**` or the Phase 3 runbook, which a
concurrent agent owns.

### 1.1 Placement decision — `c/callForOffersList` on `Lead_Funnel`

`Lead_Funnel` is an `AppPage` on `flexipage:appHomeTemplateHeaderTwoColumns` with three regions:
`region1` (the full-width header band), `region2` and `region3` (the two columns). The component
targets `lightning__AppPage` and `lightning__HomePage`, so the AppPage placement is valid as built.

**Placed in `region1`, after `pipelineStageBoard`.** Three reasons, in order of weight:

1. **It is the only full-width region.** The table renders four columns — Property (a link), Received
   (190px), Offers Due (130px), Days Remaining (170px, a pill). `region3` is the narrow column and
   would truncate it; `region2` is workable but narrower than the header band.
2. **Nothing is reordered.** The addition is a pure append inside `region1`, so no existing component
   changes position relative to any other. Both columns move down by the table's height and that is
   the whole visual delta.
3. **A deadline monitor below the fold is a deadline monitor nobody reads**, and the observation this
   implements exists because these deadlines are being missed.

⚠ **The alternative that was considered and rejected: first item in `region2`.** It puts the table in
the main column above `recentOpportunities`, which is also defensible — but it *displaces* two
incumbent components rather than appending, and it is narrower. Recorded so a future reader knows the
choice was made rather than defaulted.

### 1.2 🔴 Placement decision — `c/callForOffersPanel`, and THE TRAP IN VERIFYING IT

Required position (spec §5.3): **above the Activity component.** Delivered as item 3 of 4 in the
`sidebar` region:

| # | `sidebar` item | |
|---|---|---|
| 1 | `brokerFirmCard` | incumbent, unmoved |
| 2 | `dealDocStatus` | incumbent, unmoved |
| 3 | **`callForOffersPanel`** | **← added** |
| 4 | `flexipage:tabset` (`flexipage_tabset`) | incumbent, unmoved — holds the Activity tab |

> 🔴 **DO NOT VERIFY THIS PLACEMENT BY LINE NUMBER. IT WILL TELL YOU THE OPPOSITE OF THE TRUTH.**
>
> By raw line number the panel sits at **L1580** and `runtime_sales_activities:activityPanel` sits at
> **L1492** — so a grep says the panel is **88 lines BELOW Activity**, which reads as "it is
> underneath it". **It is not.** Line order does not imply render order in a FlexiPage, because
> facets are serialised as siblings at the top level and are pulled into position by reference.
>
> The chain, which is the only thing that decides render order, and which must be followed in full:
>
> ```
> sidebar (Region)
>   └─ item 3  componentName = callForOffersPanel          <-- renders here
>   └─ item 4  flexipage:tabset, tabs -> Facet-2f61adb5...
>                └─ Facet-2f61adb5 (Facet), FIRST tab body -> Facet-04da6a10...
>                     └─ Facet-04da6a10 (Facet)
>                          └─ runtime_sales_activities:activityPanel   <-- and Activity here
> ```
>
> The panel is item 3, the tabset is item 4, and the Activity panel is nested two facets deep inside
> item 4. The panel therefore renders **directly above Activity**, which is the requirement.
> Anyone confirming this with `grep -n activityPanel` reaches the wrong conclusion in one step.

**Why immediately above the tabset and not at the top of the sidebar.** The spec anchored the
position to a specific component ("above the Activity component"), not to the region ("at the top of
the sidebar"). Taking it literally satisfies the requirement exactly and leaves both incumbent cards
where users already expect them. Top-of-sidebar was the considered alternative and remains available
as a one-block move.

**No `<visibilityRule>` was added, deliberately.** The panel renders its own "no deadline" state for
a deal with a blank `Offer_Due_Date__c` (`OpportunitySelector.selectCallForOffersById` returns null
rather than throwing, precisely so a record-page panel does not blow up on a miss). A visibility rule
would buy nothing and would cost real risk: ARCHITECTURE records, twice measured, that a
`<visibilityRule>` bound to a FIELD evaluates **FALSE for any user lacking FLS READ on that field**,
silently — which is the defect that retired the whole `*_Driver__c` model on 2026-08-12. There is no
reason to open that failure class for a panel that already degrades correctly.

### 1.3 Live-page reconciliation, run BEFORE the edit (2026-08-14)

The brief required the live page be retrieved and diffed first. It was. The retrieve was **non-empty**
(1,557 lines) — an empty retrieve proves nothing and must never be accepted as a clean diff.

```bash
sf project retrieve start --metadata "FlexiPage:Opportunity_Record_Page" \
  --target-org usman.khan.dpeg@avanzasolutions.com \
  --target-metadata-dir <scratch> --unzip --wait 20
```

| Direction | Lines | Content |
|---|---|---|
| **org-only** (live, absent from repo) | **4** | `<rightValue>Commercial</rightValue>` ×2, `<rightValue>PSA</rightValue>` ×2 |
| **repo-only** (repo, absent from org) | **44** | `Retail` ×2 + `Under Contract (PSA)` ×2, plus 4 × 10-line `fieldInstance` blocks for Phase 1's new Opportunity fields |

**Verdict: ZERO unexplained org-only drift.** Every org-only line is a pre-migration value the repo
intentionally repointed in Phase 1 and Phase 2; the org is simply at pre-pack state, exactly as
documented. The arithmetic closes with nothing left over, which is the pass condition — "the diff
looked small" is not.

⚠ **Re-run this reconciliation immediately before P4-D.** A clean reconciliation is a snapshot, not a
standing guarantee — the 2026-08-10 permission-set cleanup found six org-only `recordTypeVisibilities`
one day after a reconciliation had recorded zero.

---

## 2. 🔴 ONE FILE, NOW THREE PHASES — who owns `Opportunity_Record_Page`

Phase 2's runbook §2 resolved this file for two phases and explicitly deferred the third: *"Phase 4
also edits this page … Phase 4 inherits the tree copy as it stands."* This section settles it.

**The tree copy is now the union of all three phases**, and a FlexiPage deploys whole:

| Phase | Edit in the tree |
|---|---|
| 1 | two `{!Record.Deal_Type__c}` criteria `Commercial` → `Retail`, plus four new Opportunity field items |
| 2 | two `{!Record.StageName}` criteria `PSA` → `Under Contract (PSA)`, gating `Move_to_About_to_Close` and `Close_Deal` |
| **4** | **`c/callForOffersPanel` in the `sidebar` region** |

### 2.1 DECISION — ownership

| Step | Deploys | From |
|---|---|---|
| **P1-D3** | Phase-1 content only | generated copy — `--phase 1 --phase4 strip` |
| **P2-D2** | Phase-1 + Phase-2 content | generated copy — `--phase 2 --phase4 strip` |
| **P4-D** | **all three phases** | **the tree, verbatim. P4-D OWNS THE TREE COPY.** |

**P4-D is the last of the three deploys of this file and the only one that deploys the tree
unmodified.** That is the whole ownership rule. It is the direct generalisation of Phase 2's
precedent (*generate a phase-scoped copy at deploy time; do not pick a regression window*), extended
by one phase.

⚠ **Note what changed for P2-D2.** Phase 2's runbook says P2-D2 deploys the **tree**. That was correct
when the tree was two phases. It is no longer: the tree now carries Phase 4's panel, so P2-D2 must
deploy a generated copy too. **Phase 2's runbook was not edited by this build** — see §6.

### 2.2 Why the earlier steps cannot simply carry the panel

Both LWC bundles import from `CallForOffersController`
(`callForOffersList` → `getUpcoming`, `callForOffersPanel` → `getForOpportunity`), so the deploy
order **P4-B (Apex) → P4-C (LWC) → the page** is a hard dependency, not a preference.

A FlexiPage naming a component the org does not have **fails the deploy**. So carrying the panel into
P1-D3 or P2-D2 would either block a phase that has no business depending on Phase 4, or — if Phase 4's
Apex and LWC happened to be live — silently ship Phase 4's UI at a time Phase 4 did not choose.
Stripping keeps the phases independent, which is what the sequencing in spec §7 says they are.

### 2.3 🔴 The generator PASSED and was WRONG — the repair

`agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js` **exited 0** against the Phase 4 tree and
emitted a copy labelled `P1-D3-safe` that **contained `c/callForOffersPanel`**, twice over
(componentName and identifier). Every assertion it held passed, because every assertion it held was
about Phase 1 and Phase 2 content.

**This is the exact drift the script's own header predicted** — *"re-run weeks after it was written,
against a tree that Phase 4 will also have edited"* — and did not guard. An assertion set that only
tests what its author already thought of is loudest at the moment it is wrong.

**Repaired in the same change, and the two failure directions are NOT symmetric:**

| Situation | If the panel is LEFT IN | If the panel is STRIPPED |
|---|---|---|
| Phase 4 not yet deployed | deploy **FAILS** — loud, no harm, but blocks an unrelated phase | correct |
| P4-D already deployed | correct | 🔴 **silently REMOVES a live component from the Opportunity record page.** No error. No log. Nobody told. |

Because the second is invisible, **`--phase4` has no default** and the script refuses to guess.

```
node agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js <out-dir> [--phase 1|2] --phase4 <strip|keep>
```

New and retained assertions, all checked against the **output**, not the input:

- Phase 1 — exactly 2 `{!Record.Deal_Type__c}` EQUAL `Retail` criteria, zero `Commercial`, and each of
  the four field items present exactly once *(retained)*
- Phase 2 — exactly 2 stage criteria in whichever form the selected phase requires *(new: previously
  only the input was checked)*
- Phase 4 — the panel present **exactly once** under `keep`, **exactly zero** times under `strip`,
  asserted in **both** directions *(new)*
- The sidebar tabset holding the Activity and Files tabs survives either transform, exactly once
  *(new — a strip that mis-walked its block boundaries would take Activity and Files with it)*

Removal is **structural**, not a text substitution: the script finds the `componentName` line, walks
out to its enclosing `<itemInstances>` block, asserts that block holds exactly one component, and
splices. A future nested container therefore cannot be swallowed silently.

**The filename is now a misnomer and was kept anyway.** Both the Phase 1 and Phase 2 runbooks spell
out `make-p1d3-copy.js` verbatim; renaming it would silently invalidate an instruction in two
documents this build is not editing.

### 2.4 Measured result of the repair (2026-08-14)

| Invocation | Result |
|---|---|
| `<out>` (the bare command both other runbooks document) | **REFUSES**, exit 1, `PHASE-4 DISPOSITION REQUIRED. Nothing written.` — names both flags and both failure directions |
| `<out> --phase4 strip` | ✅ P1-D3 copy. 2 stage criteria reverted to PSA (L132, L148); panel removed (block began L1578); 1,597 lines |
| `<out> --phase 2 --phase4 strip` | ✅ P2-D2 copy. Stage criteria left at `Under Contract (PSA)`; panel removed; 1,597 lines |
| `<out> --phase4 keep` | ✅ 1,603 lines — **byte-identical (`cmp`) to the previous script's output.** Zero regression on the previously-correct behaviour |

`diff` between the `strip` output and the old output is **exactly the 6-line panel block and nothing
else**. Tree is 1,603 lines; `strip` outputs are 1,597.

⚠ **The bare command now fails.** That is deliberate and is the right failure direction: it fails at
the moment it matters (P1-D3 / P2-D2), loudly, with the fix in the message — rather than silently
emitting a copy that is wrong in a way no downstream check can see.

---

## 3. Deploy sequence

Legend: **[ORG-Q]** = verified by an org query, **not** by a green deploy.
Phase 4 has **no data migration** — nothing is renamed and nothing is backfilled.

### P4-A — the three fields and their FLS

```
force-app/main/default/objects/Opportunity/fields/Call_For_Offers_Received_Date__c.field-meta.xml
force-app/main/default/objects/Opportunity/fields/Offer_Alert_Last_Interval__c.field-meta.xml
force-app/main/default/objects/Opportunity/fields/Offer_Alert_Due_Date__c.field-meta.xml
force-app/main/default/permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml
force-app/main/default/permissionsets/DPEG_Acquisition_View.permissionset-meta.xml
force-app/main/default/permissionsets/DPEG_Opportunity_View.permissionset-meta.xml
force-app/main/default/permissionsets/DPEG_Admin_Access.permissionset-meta.xml
```

> 🔴 **THIS STEP MUST PRECEDE P4-B, AND THE REASON IS MECHANICAL, NOT HYGIENIC.**
> A Metadata-API-deployed custom field arrives with **no field permissions for any profile, System
> Administrator included**, and `profiles/**` is `.forceignore`d so there is no profile fallback.
>
> **The field that bites is `Call_For_Offers_Received_Date__c`, and it bites through `USER_MODE`.**
> Verified in `OpportunitySelector`: the two reads backing both LWCs —
> `selectCallForOffersOpen` (L486) and `selectCallForOffersById` (L523) — are **`WITH USER_MODE`** and
> both **SELECT `Call_For_Offers_Received_Date__c`**. `USER_MODE` **throws; it does not degrade**, and
> the throw is `System.QueryException: No such column 'Call_For_Offers_Received_Date__c' on entity
> 'Opportunity'` — which is the platform's **FLS-denial signature**, not a schema error. Ship the
> Apex ahead of the grants and **both components fail for the very administrator deploying them**,
> with an error that reads like the field does not exist.
>
> ⚠ **The two alert markers do NOT have this exposure, and the distinction is worth keeping straight.**
> `Offer_Alert_Last_Interval__c` and `Offer_Alert_Due_Date__c` are selected **only** by
> `queryCallForOffersAlerts`, which is `WITH SYSTEM_MODE` (both UI reads deliberately omit them —
> `OpportunitySelector` L427 states so). FLS cannot break the batch. Their grants exist so the
> **persona can see** the marker, not so the code runs — a different failure, and a quieter one.
>
> The permission sets must be in the **same** deploy as, or a later one than, the fields: a
> `fieldPermissions` entry for a field that does not exist yet fails the deploy. Shipping all seven
> files together satisfies both constraints at once.
>
> 🔴 **RECONCILE ALL FOUR PERMISSION SETS ORG → REPO BEFORE DEPLOYING THEM.** A `PermissionSet`
> deploy **REPLACES** its entire `<fieldPermissions>` set — an org-side-only grant absent from the
> file is silently wiped, even by a deploy made for an unrelated reason. This bit Broker Protection
> twice (2026-08-05, 2026-08-06). Use Phase 1 runbook §2's retrieve command and **confirm each
> retrieved file is non-empty before trusting the diff.**

**[ORG-Q] Verify.** A green field deploy does not imply FLS:

```sql
SELECT Parent.Name, Field, PermissionsRead, PermissionsEdit
FROM FieldPermissions
WHERE Field IN ('Opportunity.Call_For_Offers_Received_Date__c',
                'Opportunity.Offer_Alert_Last_Interval__c',
                'Opportunity.Offer_Alert_Due_Date__c')
ORDER BY Parent.Name, Field
```

Expect **12 rows** — 3 fields × 4 sets (`DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`,
`DPEG_Opportunity_View`, `DPEG_Admin_Access`), which is what the repo files declare (measured
2026-08-14).

🔴 **Fewer than 12 means the grants did not land, and the symptom depends on which field is missing:**
a missing `Call_For_Offers_Received_Date__c` row is a **hard failure** of both LWCs for that persona
(the `USER_MODE` throw above); a missing marker row is an **invisible** blank on the record detail
while the alerts keep working. Do not diagnose from the screen — run the query.

### P4-B — Apex

```
force-app/main/default/classes/CallForOffersService.cls               (+ .cls-meta.xml)
force-app/main/default/classes/CallForOffersController.cls            (+ .cls-meta.xml)
force-app/main/default/classes/CallForOffersAlertBatch.cls            (+ .cls-meta.xml)
force-app/main/default/classes/CallForOffersAlertSchedule.cls         (+ .cls-meta.xml)
force-app/main/default/classes/CallForOffersServiceTest.cls           (+ .cls-meta.xml)
force-app/main/default/classes/CallForOffersControllerTest.cls        (+ .cls-meta.xml)
force-app/main/default/classes/CallForOffersAlertBatchTest.cls        (+ .cls-meta.xml)
force-app/main/default/classes/CallForOffersAlertScheduleTest.cls     (+ .cls-meta.xml)
force-app/main/default/classes/OpportunitySelector.cls                (modified — 3 CFO methods)
force-app/main/default/classes/GroupNotifier.cls                      (modified — notifyWithOutcome)
force-app/main/default/classes/GroupNotifierTest.cls                  (modified)
force-app/main/default/permissionsets/DPEG_Apex_Access.permissionset-meta.xml
```

> ⚠ **Only `CallForOffersController` is granted class access.** `CallForOffersService`,
> `CallForOffersAlertBatch` and `CallForOffersAlertSchedule` need none: a `Schedulable` started by
> `System.schedule` and a service reached only from granted Apex do not require a `classAccesses`
> entry. That is stated in `DPEG_Apex_Access`'s own comment; do not "complete the set".
>
> ⚠ `DPEG_Apex_Access` is a permission set, so the REPLACE-not-merge hazard in P4-A applies to it too.
> Reconcile it as well.

**[ORG-Q] Verify** — green deploy + `RunLocalTests`, and the notification type the batch resolves
**by name at runtime**:

```sql
SELECT DeveloperName, MasterLabel FROM CustomNotificationType
WHERE DeveloperName = 'Acquisitions_Deal_Update'
```
(Tooling API.) **Measured present 2026-08-14:** `Acquisitions_Deal_Update` / "Acquisitions - Deal
Update". 🔴 **If this returns zero rows, every alert in every pass is suppressed and nothing says
so** — `GroupNotifier` resolves the type by developer name and returns **null** when it is absent
rather than throwing, so `notifyWithOutcome` returns an all-`false` list, the batch stamps nothing,
and `AsyncApexJob` still reports `Completed` with zero errors. A green Apex deploy tells you nothing
about it. ⚠ **[CORRECTED 2026-08-14 — this note read "the alerts fail silently", which reads as
"lost". Because nothing is stamped, they are RETRIED FOR EVER: creating the type recovers every
still-open affected deal on the next pass. The full chain, the recovery boundaries and the positive
check are in §4 P4-G4, EXPANDED.]**

```sql
SELECT Id, Name, IsActive FROM ApexClass WHERE Name LIKE 'CallForOffers%'
```
Expect 8 rows (4 classes + 4 test classes).

### P4-C — the two LWC bundles

```
force-app/main/default/lwc/callForOffersList/
force-app/main/default/lwc/callForOffersPanel/
```

> **P4-B MUST precede this step.** Both bundles `import` from
> `@salesforce/apex/CallForOffersController.*`; an LWC importing an Apex method the org does not have
> fails the deploy.
>
> Jest never deploys — the suites are local only. Run the SLDS linter before this step.
> Verified locally: **99 suites / 665 tests**.

**Verify:** green deploy. Then confirm both bundles are available to App Builder before P4-D — a
FlexiPage naming an absent component fails the next step.

### P4-D — the two FlexiPages

```
force-app/main/default/flexipages/Lead_Funnel.flexipage-meta.xml
force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml
```

> 🔴 **P4-D OWNS THE TREE COPY of `Opportunity_Record_Page`** (§2.1). Deploy it from the tree,
> unmodified. Do **not** run the generator for this step — the generator exists to serve P1-D3 and
> P2-D2, and running it here would strip or downgrade content P4-D is the step that ships.
>
> ⚠ **Re-run §1.3's reconciliation immediately before this deploy**, not from this document's
> snapshot.
>
> ⚠ **`Acquisition.app-meta.xml` is NOT in this list and must not be added to it** (decision 2).

**[ORG-Q] Verify — 🔴 READ THE PAGE BACK. A GREEN DEPLOY IS NOT EVIDENCE.**
A FlexiPage deploy can roll back on a design-time error and **still report success**. This is gate
**P4-G6** — *this* runbook's §4, **not** requirements §8 G6, which is the render-probe gate — and it
is the single highest-risk item in Phase 4's declarative half.

```bash
sf project retrieve start --metadata "FlexiPage:Opportunity_Record_Page" \
  --metadata "FlexiPage:Lead_Funnel" \
  --target-org usman.khan.dpeg@avanzasolutions.com \
  --target-metadata-dir <scratch> --unzip --wait 20
```

Then assert, against the **retrieved** files:

| Check | Expected |
|---|---|
| `Lead_Funnel` contains `<componentName>callForOffersList</componentName>` | exactly 1 |
| `Opportunity_Record_Page` contains `<componentName>callForOffersPanel</componentName>` | exactly 1 |
| The panel's `<itemInstances>` block sits **before** the `<identifier>flexipage_tabset</identifier>` block **within the `sidebar` region** | true |
| `<rightValue>Retail</rightValue>` on `{!Record.Deal_Type__c}` | 2 (Phase 1 survived) |
| `<rightValue>Under Contract (PSA)</rightValue>` on `{!Record.StageName}` | 2 (Phase 2 survived) |
| `<fieldItem>Record.Listing_Status__c</fieldItem>` and the three score fields | 1 each (Phase 1 survived) |

⚠ **Do not check the third row with `grep -n` and a line comparison** — see §1.2. Line order is not
render order. Follow the region and facet chain, or confirm visually on a record page.

Then parse both retrieved files with `System.Xml.XmlDocument.Load()` on the path — **not** a
`Get-Content -Raw` cast, which mangles non-ASCII and will report a broken file as fine.

### P4-E — post-deploy gates

Not a deploy. §4. **Phase 4 is not shipped until P4-G1 and P4-G2 are done.**

---

## 4. Post-deploy gates — NOT deployable metadata, and every one fails SILENTLY

🔴 **These labels are `P4-Gn`, and they are NOT interchangeable with requirements §8's `Gn`.** The
two spaces agree only through G3. Cross-reference by document, never by bare number — the mapping,
and what happens if you do not, is in the label box at the top of this runbook.

| # | Gate | If missed |
|---|---|---|
| **P4-G1** | 🔴 **Schedule `CallForOffersAlertSchedule`.** Record the cron expression **and the owning user**. | Zero alerts. No error, no failed job, no trace of any kind. |
| **P4-G2** | 🔴 **Verify the `Acquisition` queue's membership** before P4-G1 is scheduled. | Every deadline alert reaches one person, and nothing says so. |
| **P4-G3** | **Assign the permission sets** carrying the new `fieldPermissions`. `PermissionSetAssignment` is not deployable. | The persona sees blanks, or — for `Call_For_Offers_Received_Date__c` — both components throw. |
| **P4-G4** | 🔴 **Confirm `Acquisitions_Deal_Update` exists in the org** (query in §3 P4-B). **This is the same silent-failure shape as P4-G1 and P4-G2 — see the expanded gate below; one table row under-states it.** | `GroupNotifier` returns null instead of throwing, so **every** deal in **every** pass counts as a send failure and **nothing is stamped**. ⚠ **[CORRECTED 2026-08-14 — this cell read "Every alert is silently dropped." That is right about the silence and WRONG about the permanence, in the direction that matters to a triager: because nothing is stamped, the alerts are RETRIED FOR EVER and are NOT LOST. Creating the type recovers every affected deal on the next pass.]** |
| **P4-G5** | **Seed UAT data.** | A tester sees an empty table and reasonably concludes the feature is broken. |
| **P4-G6** | **Read `Opportunity_Record_Page` back and diff it** (§3 P4-D). | A rolled-back deploy that reported success. |
| **P4-G7** | **Render probe both pages as a real acquisitions persona**, not as an administrator. | An admin smoke test proves nothing about the persona's FLS. |

### 🔴 P4-G1, EXPANDED — SCHEDULING IS THE GATE, AND ITS FAILURE MODE IS THE WORST IN THE REPO

**A scheduled-job INSTANCE is not deployable metadata.** After P4-B the class is present, compiled,
tested, covered — and **completely inert**. Zero alerts, zero errors, zero failed `AsyncApexJob` rows,
and a feature that looks shipped from every angle a deploy log or a test run can see.

```apex
System.schedule('DPEG Call For Offers Alert', '0 0 7 * * ?', new CallForOffersAlertSchedule());
```

**Record both, here, when it is done:**

| | |
|---|---|
| Cron expression | `0 0 7 * * ?` (daily, 07:00 org time) — recommended by `CallForOffersAlertSchedule`'s header: early morning puts the alert in front of the team at the start of the day it is about |
| Owning user | **(record the username at P4-G1 — not yet scheduled)** |
| `CronTrigger` Id | **(record at P4-G1)** |

🔴 **THIS FAILURE IS WORSE THAN THE SWEEPERS THIS JOB RESEMBLES, and the class header says so
explicitly.** `DealFolderSweepBatch` unscheduled leaves rows on a `Failed` status a human can list.
`RoutingRetrySweepBatch` unscheduled leaves rows on `Failed` likewise. **An unscheduled alert job
leaves no trace at all** — a deal simply never gets alerted, and *"no alert arrived"* is
**indistinguishable from** *"no deadline was near"*. There is no queue to inspect and no status to
filter. The flag that should be red is the same colour as the flag that means everything is fine.

**Verify in Setup, and by query:**

```sql
SELECT Id, CronJobDetail.Name, CronExpression, State, NextFireTime, TimesTriggered,
       CreatedBy.Username
FROM CronTrigger
WHERE CronJobDetail.Name = 'DPEG Call For Offers Alert'
```
Expect one row, `State = 'WAITING'`, a `NextFireTime` in the future. **`CreatedBy.Username` is the
owning user** — record it.

⚠ **Ownership matters less here than for `DealFolderSweepSchedule`, and the reason is worth knowing
rather than assuming.** That job's callouts run as the scheduling user, so an ungranted owner
reproduces the exact failure it exists to absorb. **This job makes no callouts**, its reads are
`WITH SYSTEM_MODE` and its writes are `AccessLevel.SYSTEM_MODE`, so FLS and CRUD cannot bite it
whoever owns it.

🔴 **One thing still depends on the owner: SHARING.** `SYSTEM_MODE` lifts CRUD and FLS and **never**
sharing. `Opportunity` internal OWD is **`ReadWrite`** (measured against `usman-dpeg` 2026-08-14), so
today every principal sees every deal and the owner is genuinely free. **If Opportunity is ever
narrowed to Private**, the locator returns zero rows for a scheduling principal who owns no deals and
`finish()` logs an all-zeros summary indistinguishable from a quiet week. That residual and its
remedy are recorded at `OpportunitySelector.queryCallForOffersAlerts`.

⚠ Re-running is free and scheduling it **more** often is harmless — the marker makes a second run in
the same day a genuine no-op (zero notifications, zero DML). Scheduling it less often delays every
rung; not scheduling it at all disables the feature entirely.

### 🔴 P4-G2, EXPANDED — THE QUEUE STAYS THE RECIPIENT. THIS GATE IS WHAT MAKES THAT SAFE.

**USER DECISION (2026-08-14): keep the existing `Acquisition` queue as the alert recipient and fix
its membership post-deploy, rather than build a new recipient.** That decision is only safe if this
gate is actually run. It is a **precondition of the decision**, not a reminder.

**Measured against `usman-dpeg`, 2026-08-14 — re-measured by this build, not copied forward:**

| Fact | Value |
|---|---|
| Queue membership today | 🔴 **exactly ONE member** (`GroupMember` `011iw000000Bc3ZAAS` → `005iw000000AJhJAAW`) |
| `queueSobject` (`queues/Acquisition.queue-meta.xml`) | 🔴 **`Lead` and `Property__c` — NOT `Opportunity`** |

Three reasons this is a real gate:

1. **Queue membership is NOT deployable metadata.** No deploy touches it — not the schedule, not the
   permission sets, not the FlexiPages. Fixing it is a manual, in-org, post-deploy step, and if it is
   skipped nothing downstream catches the omission.
2. **If missed, every offer-deadline alert goes to one person** — whichever single user already sits
   in the queue. Not the Acquisitions team. Not a distribution list. One person.
3. **The failure is structurally invisible.** "No alert arrived" and "no deadline was near" produce
   the identical observation from outside: silence. No error, no failed job, no report, nothing in
   Setup Audit Trail distinguishes "fired correctly to the wrong population" from "correctly nothing
   to alert on".

**Run this before P4-G1 is scheduled, and re-run it immediately before go-live — do not trust the
snapshot above:**

```sql
SELECT UserOrGroupId FROM GroupMember
WHERE GroupId IN (SELECT Id FROM Group WHERE DeveloperName = 'Acquisition' AND Type = 'Queue')
```

If the intended alerting population is the whole Acquisitions team, **add the missing members in
Setup before scheduling the job**. Scheduling first and fixing membership later means every alert in
that window silently reaches only the one existing member.

> ⚠ **C10 — the second, separate fact about this queue.** Its `queueSobject` list is `Lead` and
> `Property__c`. **A queue can receive a custom notification without being able to OWN the object the
> notification is about**, so the feature works as built and `queueSobject` needs no change. But this
> queue was built for **lead routing and record ownership**, and the alerting population and the
> lead-routing population can drift apart without anyone noticing. Confirm, at P4-G2, that they are
> intended to be the same people. That is a business question, not a technical one, and it is the
> reason C10 is recorded separately from membership.

### P4-G3 — assignment

`PermissionSetAssignment` is not deployable. Confirm the acquisitions persona holds
`DPEG_Acquisition_Edit` (or `_View`), and that whoever runs UAT holds one of them — **not** merely
`DPEG_Admin_Access`, which passes for reasons unrelated to the persona's grants.

### 🔴 P4-G4, EXPANDED — A MISSING NOTIFICATION TYPE DISABLES EVERY ALERT, AND THE FEATURE STILL LOOKS HEALTHY

This gate had one table row until 2026-08-14 while carrying **the same silent-failure shape as P4-G1
and P4-G2**, both of which get a section. It gets one now. The org query is in §3 P4-B; this section
is the consequence, and it is traced through the code rather than asserted.

**The chain, verified against the classes on disk 2026-08-14:**

| Step | What happens when `Acquisitions_Deal_Update` is absent |
|---|---|
| `GroupNotifier.resolveNotificationTypeId()` | `NotificationTypeSelector.selectByDeveloperName` finds nothing → caches and returns **`null`**. It does **not** throw. |
| `GroupNotifier.notifyWithOutcome(requests)` | Pre-fills the outcome list with `false`, hits the `notificationTypeId == null` branch, logs one `System.debug(LoggingLevel.WARN, …)` and **returns early — an all-`false` list, index-aligned**. No `CustomNotification.send()` is ever attempted. |
| `CallForOffersAlertBatch.execute` | Every element of `outcomes` is `false`, so every deal increments `chunkSendFailures` and **`toStamp` stays empty**. `stampMarkers` is guarded by `if (!toStamp.isEmpty())` and therefore **never runs**. |
| `finish()` | One `System.debug(LoggingLevel.INFO, …)` line reading `notified=0 stamped=0 sendFailures=<every deal that was owed an alert>`. |

🔴 **WHAT AN OBSERVER SEES: nothing.** The batch completes. `AsyncApexJob` shows `Completed` with
`NumberOfErrors = 0` — no chunk threw, so no chunk failed. Both traces are `System.debug` lines
inside an async transaction, which are **not retained without an active trace flag on the running
user**, and nobody is watching an alert job's log at 07:00. There is no exception, no failed job, no
error record, and no field left in a state a report can filter on.

> 🔴 **BUT THE ALERTS ARE RETRIED FOR EVER AND ARE NOT LOST — READ THIS BEFORE PRIORITISING.**
>
> ⚠ **[CORRECTED 2026-08-14 — the §4 table cell, and the §3 P4-B verify note, both said the alerts
> "fail silently" / are "silently dropped", full stop. That is right about the silence and WRONG
> about the permanence, and the error runs in the direction that changes a triager's decision.]**
>
> **Nothing is stamped**, and the marker pair (`Offer_Alert_Last_Interval__c` /
> `Offer_Alert_Due_Date__c`) is the *only* thing that suppresses a re-alert. So every affected deal
> stays exactly as eligible on the next pass as it was on this one. **Create the notification type
> and the very next run alerts every deal that was owed one** — including the ones missed on every
> prior day, at whichever ladder rung they have since reached.
>
> That makes this a **recoverable outage, not a data-loss event**: it is urgent because the team is
> flying blind on live offer deadlines while it lasts, **not** because a window of alerts is gone for
> good. Triage it accordingly — and do **not** "repair" it by hand-stamping markers, which is the one
> action that would convert a recoverable outage into a permanent gap.
>
> ⚠ **The recovery is complete but not time-faithful, and the two boundaries were checked rather
> than assumed.** `CallForOffersService.evaluate` derives the rung from `today.daysBetween(dueDate)`,
> so history is **not** replayed: a deal whose 7-day and 3-day rungs both elapsed during the outage
> gets **one** notification, at whichever rung it sits in on recovery day — not the two it was owed.
> A deal whose due date passed **entirely** during the outage is still recovered: the locator
> (`OpportunitySelector.queryCallForOffersAlerts`) has a ceiling of `TODAY + 7` and **deliberately no
> floor**, so a long-overdue deal stays in scope and, being unmarked, fires once at rung 0. The one
> population that is **not** recoverable is a deal **CLOSED** during the outage — `IsClosed = FALSE`
> removes it permanently, and no alert it was owed will ever be sent. Recovery restores the
> *feature*, not the *missed days*.

**The positive check, which is the useful one — there is no negative signal to watch for:**

```sql
SELECT COUNT() FROM Opportunity
WHERE Offer_Due_Date__c != null AND IsClosed = false AND Offer_Alert_Last_Interval__c != null
```

After the first scheduled run following a day on which any open deal sat inside the 7-day band, this
must be **non-zero**. Zero means either "no deal was inside the band" or "the notification type is
missing / the queue resolved to nobody / the job never ran" — the four are indistinguishable from the
outside, which is precisely why P4-G1, P4-G2 and P4-G4 are each verified **by their own query before
go-live** rather than by watching for a symptom afterwards.

⚠ **A green Apex deploy and a green `RunLocalTests` tell you nothing about this.** The type is
resolved **by developer name at runtime**; `CustomNotificationType` is not a compile-time reference,
so nothing fails to deploy and no test fails when it is absent.

⚠ **The type is REUSED here, not created by this pack** (§0 decision 4) — it was measured present in
`usman-dpeg` on 2026-08-14. That is exactly why this gate exists: nothing in Phase 4's deploy list
would re-create it if it were deleted, renamed, or absent in a different target org.

### 🔴 P4-G5, EXPANDED — UAT NEEDS SEEDED DATA OR IT WILL FAIL FOR THE WRONG REASON

**Measured against `usman-dpeg`, 2026-08-14 — re-measured by this build:**

```sql
SELECT COUNT() FROM Opportunity WHERE Offer_Due_Date__c != null AND IsClosed = false
```
> **Total number of records retrieved: 0.**

**There are ZERO open Opportunities carrying an offer due date in this org.** Neither the Lead Funnel
table nor the record-page panel has anything to render against live data.

🔴 **A tester who opens the Lead Funnel tab after a perfect deploy will see an empty table and
reasonably, but wrongly, conclude the component is broken.** That is a false negative that will cost a
debugging cycle against working code, and it is entirely avoidable.

**Seed before UAT — at minimum one open Opportunity with:**

| Field | Why |
|---|---|
| `Offer_Due_Date__c` | the only field that puts a deal on either surface |
| `Call_For_Offers_Received_Date__c` | otherwise the Received cell falls back to the **labelled** "Deal arrived …" form, which is a *different* fact — seed at least one of each so UAT sees both forms and can check the fallback wording renders |
| `Sale_Process__c`, `Listing_Broker_Name__c`, `Deal_Room_Link__c` | the panel's remaining rows; without them UAT cannot tell "blank because empty" from "blank because broken" |

**Seed several due dates across the bands** — the ladder is 7 / 3 / 1 / 0 days, so a spread of due
dates is what makes the colour-coded urgency badge testable at all. A single deal exercises one band
out of six.

### P4-G7 — render probe, as a persona

Confirm on a real acquisitions persona (not an administrator):

- the call-for-offers table renders on the **Lead Funnel** tab, full width, below the stage board;
- the panel renders on an Opportunity record page **above the Activity tab**, not below it;
- a deal with **no** `Offer_Due_Date__c` shows the panel's "no deadline" state and does **not** error.

---

## 5. Residuals — recorded in the developer's own words, not softened

These were surfaced by the build and are **accepted, not open defects**. Each is a decision someone
took deliberately, and each will look like a bug to the next reader who finds it cold.

### 5.1 The received date is NON-MONOTONIC BY DESIGN

`Call_For_Offers_Received_Date__c` is **last-email-wins**: a later call-for-offers email about the
same deal overwrites the date. **A stale forward stating an old send time moves the date backward.**

That is the lesser of two evils and was chosen as such: the alternative — fill-if-blank, or
monotonic-forward-only — would **report a three-week-old forward as new**, which is worse, because
the whole point of the column is to tell an analyst how fresh the campaign information is.

⚠ **It changes no alert decision.** `CallForOffersAlertBatch`'s header records that this was checked
rather than assumed: the marker keys on the **due** date at all three points (ladder position,
re-arm comparison, and the snapshot it stamps), the notification body is derived from the deadline,
and `queryCallForOffersAlerts` **deliberately does not select the received date at all** —
`OpportunitySelectorTest.queryCallForOffersAlerts_doesNotSelectTheReceivedDate` pins that, so adding
it later is a decision someone has to take on purpose.

### 5.2 `SCOPE = 200` is a BLAST-RADIUS choice, not a rationed budget

The brief instructed that `SCOPE` be derived from this org's per-transaction
`Messaging.CustomNotification.send()` ceiling, measured before being fixed. **It was measured, and the
answer is that no such count ceiling exists at any scale this job can reach**, so the instruction's
premise does not hold and `SCOPE` is derived from what actually binds instead.

| Probe (`usman-dpeg`, 2026-08-14) | Result |
|---|---|
| 300 sequential `send()` calls in ONE transaction | `sentOk = 300`, no error, CPU 2,162 / 10,000 ms, DML 0/150, SOQL 2/100 |
| `send()` in a loop guarded only on CPU (stop at 8,500 ms) | `sentOk = **1,371**`, **no error of any kind**, CPU 8,501 ms |

⇒ **1,371 sends in one transaction with no exception.** No `LimitException`, no count cap; `send()`
consumes **zero SOQL and zero DML**. What it consumes is **CPU, at a measured 6.20 ms per send**
(8,501 / 1,371). `System.Limits` exposes no counter for it and the org `/limits` REST resource lists
no notification entry (71 limit rows, zero matching), so CPU is not merely the first thing to bind —
it is the only observable cost.

```
async CPU budget for a batch execute()      60,000 ms
measured cost per notification                  6.20 ms
200 deals, WORST CASE (every one alerts)   200 x 6.20 = 1,240 ms
share of the async CPU budget                    ~2%   (a 48x margin)
```

200 is the platform's own default batch scope, and at that size a failed chunk costs at most 200 deals
**one pass** — they stay in the locator, unstamped, and alert on the next run.

⚠ **THE HONEST LIMIT OF THE MEASUREMENT:** probe 2 stopped *itself* at 8,500 ms of a 10,000 ms
**synchronous** budget, so it establishes *"no count ceiling at or below 1,371"* and **not** *"no
count ceiling exists"*. Anyone raising `SCOPE` past ~1,300 must re-measure. Nothing here needs to.
⚠ **A daily org allocation on custom notifications, if one exists, was NOT measurable** — it appears
in neither `Limits` nor `/limits`.

### 5.3 The Received column widened 130 → 190px, and jsdom cannot check it

The cell renders either a bare date (`Jul 1, 2026`) or the labelled fallback
`Deal arrived Jul 1, 2026` — roughly 13 characters longer — and a datatable text cell truncates with
an ellipsis. **Left at the 130px the bare date needed, the caveat is the part that disappears,
leaving the reader looking at a date whose qualification has been cut off** — worse than either
alternative, because a silently unqualified date reads as the fact it is not.

⚠ **NOT MEASURED IN A BROWSER, and it cannot be from the Jest suite: jsdom performs no layout, so
every width and overflow read is 0 there.** The suite asserts the **configured** width only. **The
rendered fit is a human UAT check** — add it to P4-G5's list: display one row of each form side by side
and confirm neither truncates.

⚠ Related, and easy to "clean up" into a defect: the prefix is the whole point and **must not become
a glyph**. A `~`, an asterisk or a tooltip is scanned past in a dense table; "Deal arrived" is read.
Do not collapse it to `formatDate(r.receivedDate || r.dealArrivedDate)` — that single expression **is**
the defect this change removed, and it would be invisible in review because the column would still
look right.

---

## 6. Handoffs — what this build did NOT do

| Item | Owner |
|---|---|
| Deploying anything | 🔴 `salesforce-devops` |
| P4-G1 (schedule + record cron and owner), P4-G2 (queue membership), P4-G3 (assignment), **P4-G4 (confirm the notification type)**, P4-G5 (UAT seed) | 🔴 `salesforce-devops` / admin — all in-org, none deployable |
| 🔴 **Phase 1's runbook §3 P1-D3 and Phase 2's runbook §2 both document the generator's BARE invocation, which now REFUSES.** Neither document was edited by this build. Whoever executes P1-D3 or P2-D2 must use `--phase4 strip` (or `keep` if P4-D has already landed) per §2.3. | 🟤 `salesforce-solution-architect` — a two-line amendment to each of those two runbooks, or the operator reads §2 here |
| ⚠ **Phase 2's runbook §2 states "P2-D2 deploys the tree copy". That is no longer correct** — the tree now carries Phase 4's panel, so P2-D2 needs a generated `--phase 2 --phase4 strip` copy. | same as above |
| Phase 3's declarative work (`objects/{LOI__c,Contract_Review__c}/**`, `pathAssistants/**`, its runbook) | 🟤 concurrent agent — deliberately untouched |
| Apex, LWC and Jest for Phase 4 | 🟢 `salesforce-developer` — already delivered and verified (211 tests / 0 failures, 95–100% coverage, 99 Jest suites / 665 tests) |
| Deciding whether the Acquisitions **alerting** population and the Acquisitions **lead-routing** population are the same people (C10) | business owner, at P4-G2 |

---

## 7. Rule-gate record (`.claude/rules/salesforce-global-rule.md`)

```
intent=type | best_matched_skill=sf-flexipage | skill_selection=complete
```

| Metadata type in scope | Skill | API context |
|---|---|---|
| `FlexiPage` (2 files) | `sf-flexipage` — **loaded** | `mcp=unavailable`, `mcp_tools=none` |

**Real MCP attempt, and its result.** `.mcp.json` declares a `salesforce` MCP server with
`--toolsets all`, but **no `salesforce-api-context` tool is exposed to this session's tool surface**,
so none (`get_metadata_type_context`, `get_metadata_type_fields`, `search_metadata_types`, …) could be
invoked. Recorded as `mcp=unavailable` after inspecting the configured servers; fell back to the
loaded `sf-flexipage` skill per constraint 3.

**No other metadata type was generated.** The fields, permission sets, Apex and LWC were already on
disk from earlier builds; this build touched only FlexiPages, plus one non-metadata Node script.

Skill checks applied to both edited files: unique `<identifier>` values (verified — zero duplicates
in either file before or after), unique `<flexiPageRegions><name>` values, new components added as
additional `<itemInstances>` inside an **existing** region rather than a second region with a
duplicate name, no `<mode>` tags, and no property values requiring XML entity encoding.

### XML validation

`System.Xml.XmlDocument.Load()` on the path — **not** a `Get-Content -Raw` cast, which mangles
non-ASCII and reports a broken file as fine.

| File | Result |
|---|---|
| `flexipages/Lead_Funnel.flexipage-meta.xml` | ✅ 38 elements, 0 comments |
| `flexipages/Opportunity_Record_Page.flexipage-meta.xml` | ✅ 1,131 elements, 0 comments |
| generator output, `--phase 1 --phase4 strip` | ✅ 1,127 elements |
| generator output, `--phase 2 --phase4 strip` | ✅ 1,127 elements |
| generator output, `--phase 1 --phase4 keep` | ✅ 1,131 elements |

**5 parsed / 0 failed.** The 1,131 → 1,127 delta is exactly the panel's four elements
(`itemInstances`, `componentInstance`, `componentName`, `identifier`), which independently confirms
the strip removes the block and nothing adjacent.

**Double-hyphen sweep: 0.** Neither file contains any XML comment at all, so the `--` hazard that
broke two metadata files earlier today cannot arise here. ⚠ **No XML comment was added to either
FlexiPage, deliberately** — App Builder rewrites these files on every in-org edit and there is no
in-repo precedent for a comment surviving that. This runbook is the documentation instead.
