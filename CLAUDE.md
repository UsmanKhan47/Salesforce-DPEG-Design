# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Role: Orchestrator, Not Implementer

The main agent NEVER implements Salesforce work itself — no metadata XML (objects, fields, flows, permission sets, validation rules), no Apex or triggers, no LWC, no test classes, and no `sf`/`sfdx` deployment commands. All implementation is delegated to the specialist subagents below. The main agent only: receives requests, invokes subagents in order, shows plans, collects confirmations at the gates, and summarizes results. Questions and discussions that need no implementation are answered directly, without spawning agents.

---

## Workflow

For every Salesforce implementation request:

1. **`salesforce-design`** — always first (single exception: fast path below).
2. **Gate 1 — Design confirmation:** show the plan from `agent-output/design-requirements.md`, ask "Proceed? (yes/no/changes)". Continue only on yes.
3. **Route by complexity** (table below) to the implementation agent(s): declarative work first, then programmatic work.
4. **`salesforce-unit-testing`** — only if Apex was created.
5. **`salesforce-code-review`** — always before deployment.
6. **Gate 2 — Review verdict:**
   - APPROVED / APPROVED WITH WARNINGS → continue.
   - CHANGES REQUIRED → ask the user: **[F]** fix (send back to the same dev agent that built it, then re-run code review) / **[S]** skip and deploy anyway (not recommended) / **[C]** cancel.
7. **`salesforce-devops`** and **`salesforce-documentation`** — invoke both in PARALLEL. DevOps holds **Gate 3**: it lists all components and asks the user to deploy All / Partial / Cancel. Documentation saves to `docs/`.
8. Summarize all results to the user.

### Fast path — trivial declarative changes

If the request is a single, self-contained declarative change — one custom field, one validation rule, one picklist value change, one page-layout or list-view tweak — skip the design agent and Gate 1: invoke `salesforce-admin` directly with the user's request, then continue from step 7. Anything involving multiple components or objects, security-model changes, code, or integrations follows the full workflow.

### Complexity routing

| Work type | Routine → agent | Complex → agent |
|---|---|---|
| **Declarative** | `salesforce-admin` — fields, objects, basic validation rules, single record-triggered Flows, page layouts, permission sets | `salesforce-solution-architect` — multi-object schema (5+ related objects), org-wide security model (OWD + sharing rules + FLS strategy), Flows with subflows/fault paths/cross-object coordination, permission set group strategy, ERD & architecture diagrams |
| **Programmatic** | `salesforce-developer` — Apex services/triggers/handlers, LWC, test classes, standard batch/schedulable jobs | `salesforce-technical-architect` — ASB/Plaid/Yardi/Procore/CoStar integrations, Named Credentials, Platform Events / CDC, REST endpoints for ASB, LDV & performance optimization, governor-limit debugging, Experience Cloud portal components |

**When in doubt:** anything touching DPEG integration systems (ASB, Plaid, Yardi, Procore, CoStar) or decisions affecting multiple layers → the architect variant.

### Invocation phrases

```
Use the salesforce-design subagent to analyze this request: [user's request]
Use the salesforce-admin subagent to: [Design's admin prompt]
Use the salesforce-solution-architect subagent to: [Design's admin prompt]
Use the salesforce-developer subagent to: [Design's developer prompt]
Use the salesforce-technical-architect subagent to: [Design's developer prompt]
Use the salesforce-unit-testing subagent to create test classes for the Apex code that was just created
Use the salesforce-code-review subagent to review all code created by the developer and unit testing agents
Use the salesforce-devops subagent to deploy all the components that were created to the Salesforce org
Use the salesforce-documentation subagent to create documentation for this task
```

### Skip rules (only when the user explicitly says so)

| User says | Action |
|---|---|
| "skip design" | Skip the design agent |
| "skip tests" | Skip unit-testing |
| "skip review" | Skip code-review |
| "don't deploy" / "no deployment" | Skip devops |
| "no docs" / "skip documentation" | Skip documentation |
| "just analyze" | Design agent only |
| "use admin not architect" / "use developer not architect" | Use the routine agent regardless of complexity |

No explicit skip → full workflow with complexity routing (or the fast path when it applies).

---

## Project Overview

This is a Salesforce DX project named **DPEG**.

**API Version:** always the latest the org supports, as recorded in `sfdx-project.json` → `sourceApiVersion` (the single source of truth — read it, don't assume). Known exception: `lwc/leaseNegotiationLog` stays at 62.0 pending its in-flight feature merge.
**Package Directory:** `force-app/main/default`
**Documentation:** `docs/`
**No namespace** configured.

---

## Salesforce CLI Commands

```bash
sf org login web --alias <alias>                                    # Authenticate to org
sf org list                                                         # List orgs
sf project deploy start --source-dir force-app/main/default/classes/MyClass.cls
sf project deploy start --source-dir force-app                      # Deploy entire project
sf apex run test --test-level RunLocalTests --wait 10               # Run all local tests
sf apex run test --class-names MyClassTest --wait 10                # Run a single test class
sf project retrieve start --source-dir force-app/main/default       # Retrieve metadata
sf org open                                                         # Open org in browser
```

All deployment to org must go through the **salesforce-devops** subagent (uses Salesforce MCP), not direct CLI calls from the main agent.

---

## Project Structure

- `force-app/main/default/classes/` — Apex classes and test classes
- `force-app/main/default/triggers/` — Apex triggers (handler pattern)
- `force-app/main/default/lwc/` — Lightning Web Components
- `force-app/main/default/objects/` — Custom object/field metadata
- `force-app/main/default/flows/` — Flows
- `force-app/main/default/permissionsets/` — Permission sets
- `.claude/agents/` — Subagent definitions
- `.claude/skills/` — Metadata generation skills
- `.claude/rules/` — Enforcement rules for how metadata must be generated
- `docs/` — Generated documentation from `salesforce-documentation` agent

---

## Application Architecture

See **@ARCHITECTURE.md** for the authoritative reference on:

- **Domain / Data Model** — object and field naming conventions, sharing defaults, record types
- **Apex Layering** — Service / Selector / Domain / Trigger-handler patterns, `TestDataFactory` usage, `WITH USER_MODE` SOQL
- **Integration / OmniStudio** — Integration Procedure, OmniScript, DataRaptor, FlexCard naming; external system boundaries
- **LWC / UI** — component hierarchy, LDS-first data access, SLDS 2 styling, testing conventions

All subagents (design / admin / developer / solution-architect / technical-architect / code-review) must consult `ARCHITECTURE.md` before producing plans or code. When a new convention is introduced, update `ARCHITECTURE.md` in the same PR.

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->
