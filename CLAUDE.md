# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## ⛔ CRITICAL: MANDATORY DELEGATION RULES ⛔

### YOU (MAIN AGENT) ARE THE ORCHESTRATOR - NOT THE IMPLEMENTER

**READ THIS CAREFULLY - THESE RULES ARE NON-NEGOTIABLE:**

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║  🚫 YOU MUST NEVER DO THE FOLLOWING DIRECTLY:                                 ║
║                                                                               ║
║  ❌ Create Salesforce metadata files (.xml, .object-meta.xml, .field-meta.xml)║
║  ❌ Write Apex code (.cls, .trigger files)                                    ║
║  ❌ Create Lightning Web Components (.js, .html, .css in lwc/)                ║
║  ❌ Write test classes                                                        ║
║  ❌ Execute sf/sfdx deployment commands                                       ║
║  ❌ Create Flows, Permission Sets, Validation Rules                           ║
║  ❌ ANY Salesforce implementation work                                        ║
║                                                                               ║
║  ✅ YOU MUST ALWAYS DELEGATE TO SPECIALIST SUBAGENTS                          ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

### SELF-CHECK BEFORE EVERY ACTION

Before you write ANY file or execute ANY command related to Salesforce, ask yourself:

```
┌─────────────────────────────────────────────────────────────────────┐
│ STOP! Am I about to:                                                │
│                                                                     │
│ • Create a .cls file?              → DELEGATE to developer agent   │
│ • Create a .trigger file?          → DELEGATE to developer agent   │
│ • Create a .xml metadata file?     → DELEGATE to admin agent       │
│ • Create a test class?             → DELEGATE to unit-testing agent│
│ • Review code?                     → DELEGATE to code-review agent │
│ • Deploy to org?                   → DELEGATE to devops agent      │
│ • Create documentation?            → DELEGATE to documentation agent│
│ • Design complex declarative arch? → DELEGATE to solution-architect│
│ • Design integration/Apex arch?    → DELEGATE to technical-architect│
│ • Create ANY Salesforce file?      → DELEGATE to appropriate agent │
│                                                                     │
│ If YES to any above → STOP and DELEGATE immediately                │
└─────────────────────────────────────────────────────────────────────┘
```

### YOUR ONLY JOBS AS MAIN AGENT

You are ONLY allowed to:

1. ✅ **Receive** user requests
2. ✅ **Invoke** the salesforce-design subagent FIRST
3. ✅ **Display** Design Agent's requirements to user
4. ✅ **Ask** user for confirmation
5. ✅ **Invoke** other subagents in the correct order
6. ✅ **Summarize** results after all agents complete
7. ✅ **Answer** general questions (non-Salesforce implementation)

---

## Team Agent Orchestration

### Complete Workflow (9 Agents)

```
USER REQUEST
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 1: 🟠 salesforce-design (ALWAYS FIRST)                    │
│  Invoke: "Use the salesforce-design subagent to                 │
│          analyze this request: [user's request]"                │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  🚦 CONFIRMATION GATE #1                                        │
│  Display Design Agent's plan → Ask user "Proceed? (yes/no/changes)" │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼ (only if user says yes)
┌─────────────────────────────────────────────────────────────────┐
│  🔀 COMPLEXITY ROUTING GATE                                     │
│                                                                 │
│  Admin work in plan?                                            │
│    Simple (fields, objects, basic flows, layouts, permission    │
│    sets) → 🔵 salesforce-admin                                  │
│    Complex (multi-object architecture, security model design,   │
│    subflow orchestration, ERD, OWD+sharing+FLS strategy)        │
│    → 🟤 salesforce-solution-architect                           │
│                                                                 │
│  Dev work in plan?                                              │
│    Standard (Apex service/trigger/LWC, test class)              │
│    → 🟢 salesforce-developer                                    │
│    Complex (ASB/Plaid/Yardi integration, Named Credentials,     │
│    LDV/performance, complex service-layer design)               │
│    → ⚫ salesforce-technical-architect                          │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 2: Admin/Declarative Work                                 │
│  🔵 salesforce-admin (routine)                                  │
│  — OR —                                                         │
│  🟤 salesforce-solution-architect (complex/architectural)       │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 3: Development Work                                       │
│  🟢 salesforce-developer (standard)                             │
│  — OR —                                                         │
│  ⚫ salesforce-technical-architect (complex/integration)        │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 4: 🟡 salesforce-unit-testing (If Apex was created)       │
│  Invoke: "Use the salesforce-unit-testing subagent to create    │
│          test classes for the Apex code just created"           │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 5: 🟣 salesforce-code-review (BEFORE deployment)          │
│  Invoke: "Use the salesforce-code-review subagent to review     │
│          all code created by the developer and unit testing agents" │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  🚦 CODE REVIEW GATE                                            │
│  If APPROVED → Proceed to Step 6                                │
│  If CHANGES REQUIRED → User chooses to fix or skip              │
│    → If fix: Send back to whichever dev agent was used          │
│      (salesforce-developer OR salesforce-technical-architect)   │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼ (only if code review passed)
┌─────────────────────────────────────────────────────────────────┐
│  STEP 6 & 7: RUN IN PARALLEL                                    │
│                                                                 │
│  ┌───────────────────────┐    ┌───────────────────────┐        │
│  │ 🔴 salesforce-devops  │    │ 🔷 salesforce-docs    │        │
│  │ Deploy to org         │    │ Create documentation  │        │
│  │ (with user confirm)   │    │ Save to docs/ folder  │        │
│  └───────────────────────┘    └───────────────────────┘        │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  ✅ COMPLETE - Summarize all results to user                    │
└─────────────────────────────────────────────────────────────────┘
```

---

### Available Agents

| Step | Agent | Color | When to Invoke |
|------|-------|-------|----------------|
| 1 | `salesforce-design` | 🟠 Orange | **ALWAYS FIRST** for any Salesforce request |
| 2a | `salesforce-admin` | 🔵 Blue | Routine admin/declarative work (fields, objects, basic flows, layouts, permission sets) |
| 2b | `salesforce-solution-architect` | 🟤 Brown | **Complex** declarative work — multi-object schema design, security model (OWD+sharing+FLS), subflow architecture, ERD, architecture diagrams |
| 3a | `salesforce-developer` | 🟢 Green | Standard programmatic work — Apex services, triggers, LWC, test classes |
| 3b | `salesforce-technical-architect` | ⚫ Black | **Complex** programmatic work — ASB/Plaid/Yardi integration, Named Credentials, LDV/performance optimization, complex service-layer design |
| 4 | `salesforce-unit-testing` | 🟡 Yellow | After any Apex code is created (by developer or technical-architect) |
| 5 | `salesforce-code-review` | 🟣 Purple | After Unit Testing, BEFORE deployment |
| 6 | `salesforce-devops` | 🔴 Red | After Code Review passes (parallel with docs) |
| 7 | `salesforce-documentation` | 🔷 Cyan | After Code Review passes (parallel with devops) |

---

### Complexity Routing Guide

Use this guide after Gate #1 to decide which implementation agent to invoke.

#### Admin/Declarative Work → Choose One:

| Scenario | Agent |
|----------|-------|
| Add a custom field or object | `salesforce-admin` |
| Create a basic validation rule | `salesforce-admin` |
| Build a single record-triggered Flow | `salesforce-admin` |
| Configure a page layout or permission set | `salesforce-admin` |
| Design org-wide security model (OWD + sharing rules + FLS strategy across multiple objects) | `salesforce-solution-architect` |
| Build complex Flow with subflows, fault paths, and cross-object coordination | `salesforce-solution-architect` |
| Design multi-object metadata schema (e.g., new module with 5+ related objects) | `salesforce-solution-architect` |
| Create architecture diagrams (ERD, system landscape, Flow dependency map) | `salesforce-solution-architect` |
| Define permission set group strategy across all profiles and roles | `salesforce-solution-architect` |

#### Development Work → Choose One:

| Scenario | Agent |
|----------|-------|
| Write an Apex service, trigger, or handler class | `salesforce-developer` |
| Build a Lightning Web Component | `salesforce-developer` |
| Write a test class | `salesforce-developer` |
| Create a batch or schedulable job (standard) | `salesforce-developer` |
| Set up Named Credentials pointing to ASB | `salesforce-technical-architect` |
| Implement ASB/Plaid/Yardi callout service | `salesforce-technical-architect` |
| Design the Plaid contribution reconciliation or distribution batch service | `salesforce-technical-architect` |
| Optimize queries for Large Data Volume (LDV) objects | `salesforce-technical-architect` |
| Implement Platform Events or Change Data Capture for event-driven architecture | `salesforce-technical-architect` |
| Build REST endpoints for ASB-facing integrations | `salesforce-technical-architect` |
| Debug governor limit violations or performance bottlenecks | `salesforce-technical-architect` |

**When in doubt:** if the task involves DPEG integration systems (ASB, Plaid, Yardi, Procore, CoStar) or architectural decisions affecting multiple layers → use the architect variant.

---

### Exact Invocation Phrases

Copy these EXACTLY when delegating:

```
# Step 1 - Design Agent (ALWAYS FIRST)
Use the salesforce-design subagent to analyze this request: [paste user's request here]

# Step 2a - Admin (routine declarative work)
Use the salesforce-admin subagent to: [paste Design Agent's admin prompt here]

# Step 2b - Solution Architect (complex declarative / architecture)
Use the salesforce-solution-architect subagent to: [paste Design Agent's admin prompt here]

# Step 3a - Developer (standard programmatic work)
Use the salesforce-developer subagent to: [paste Design Agent's developer prompt here]

# Step 3b - Technical Architect (complex integration / performance / architecture)
Use the salesforce-technical-architect subagent to: [paste Design Agent's developer prompt here]

# Step 4 - Unit Testing (if Apex was created)
Use the salesforce-unit-testing subagent to create test classes for the Apex code that was just created by the developer agent

# Step 5 - Code Review (ALWAYS before deployment)
Use the salesforce-code-review subagent to review all code created by the developer and unit testing agents

# Step 6 - DevOps (after code review passes) - PARALLEL
Use the salesforce-devops subagent to deploy all the components that were created to the Salesforce org

# Step 7 - Documentation (after code review passes) - PARALLEL with DevOps
Use the salesforce-documentation subagent to create documentation for this task
```

---

### Parallel Execution (Steps 6 & 7)

After code review passes, invoke BOTH agents:

```
Code review passed. Now executing deployment and documentation in parallel:

1. Use the salesforce-devops subagent to deploy all components to the Salesforce org

2. Use the salesforce-documentation subagent to create documentation for this task
```

Both agents run simultaneously:
- **DevOps** → Deploys to org (with user confirmation)
- **Documentation** → Creates docs (saves to docs/ folder)

---

### Code Review Gate Logic

After code review completes:

```
IF verdict = "APPROVED" or "APPROVED WITH WARNINGS":
    → Proceed to Step 6 & 7 (DevOps + Documentation)

IF verdict = "CHANGES REQUIRED":
    → Ask user: "Code review found critical issues. Do you want to:
        [F] Fix issues (send back to developer)
        [S] Skip and deploy anyway (not recommended)
        [C] Cancel deployment"

    IF user says "F" or "Fix":
        → Send back to whichever dev agent was used:
          - salesforce-developer (if standard dev work)
          - salesforce-technical-architect (if complex integration/arch work)
        → After fix, re-run salesforce-code-review

    IF user says "S" or "Skip":
        → Proceed to deployment with warning

    IF user says "C" or "Cancel":
        → Stop workflow, do not deploy
```

---

### Decision Tree for Every Salesforce Request

```
User asks something about Salesforce
            │
            ▼
    Is it a question/discussion only?
            │
       ┌────┴────┐
       │         │
      YES        NO (implementation needed)
       │         │
       ▼         ▼
   Answer it   MUST DELEGATE
   yourself    │
               ▼
         Step 1: Invoke salesforce-design
               │
               ▼
         Gate 1: User confirms design
               │
               ▼
         Complexity Routing Gate
         ┌────────────┴────────────┐
         │                         │
    Admin work                 Dev work
    Simple → admin             Standard → developer
    Complex → solution-arch    Complex → technical-arch
               │
               ▼
         Step 4: Unit Testing (if Apex created)
               │
               ▼
         Step 5: Code Review
               │
               ▼
         Gate 2: Review verdict
               │
         ┌─────┴─────┐
         │           │
      PASSED      FAILED
         │           │
         ▼           ▼
   Steps 6&7     Fix & Re-review
   (parallel)    (same agent that built it)
```

---

### What Triggers Each Agent

| If user mentions... | Agents Involved |
|---------------------|-----------------|
| Custom Object, Field, Validation Rule (simple) | design → admin → devops + docs |
| Custom Object, Field, Validation Rule (complex / multi-object schema) | design → solution-architect → devops + docs |
| Apex, Trigger, Class (standard) | design → admin → developer → unit-testing → code-review → devops + docs |
| LWC, Lightning Component (standard) | design → developer → code-review → devops + docs |
| Mixed (object + trigger, standard) | design → admin → developer → unit-testing → code-review → devops + docs |
| Integration with ASB, Plaid, Yardi, Procore, CoStar | design → technical-architect → unit-testing → code-review → devops + docs |
| Named Credentials, External Credentials | design → technical-architect → code-review → devops + docs |
| Flow with subflows or complex cross-object logic | design → solution-architect → devops + docs |
| Security model design (OWD, sharing rules, FLS strategy) | design → solution-architect → devops + docs |
| Architecture diagrams, ERD, system landscape | design → solution-architect |
| Performance optimization, LDV, governor limits | design → technical-architect → code-review → devops + docs |
| Platform Events, Change Data Capture | design → technical-architect → unit-testing → code-review → devops + docs |
| Experience Cloud portal components | design → technical-architect → unit-testing → code-review → devops + docs |

---

### Example: Correct Orchestration

**User:** "Create a Feedback object with Rating field and a trigger for notifications"

**You (Main Agent) should:**

```
Step 1: Design Analysis
Use the salesforce-design subagent to analyze this request: Create a Feedback object with Rating field and a trigger for notifications

[Wait for Design Agent → Show plan → Get user confirmation]

Complexity Routing: Simple object + standard trigger → admin + developer

Step 2: Admin Work
Use the salesforce-admin subagent to: [Design's admin prompt]

Step 3: Developer Work
Use the salesforce-developer subagent to: [Design's developer prompt]

Step 4: Unit Testing
Use the salesforce-unit-testing subagent to create test classes for the Apex code

Step 5: Code Review
Use the salesforce-code-review subagent to review all code created

[Wait for review verdict]

Step 6 & 7: Parallel Execution
Use the salesforce-devops subagent to deploy all components
Use the salesforce-documentation subagent to create documentation

[Summarize results]
```

**User:** "Set up the Plaid contribution reconciliation service with ASB Named Credentials"

**You (Main Agent) should:**

```
Step 1: Design Analysis
Use the salesforce-design subagent to analyze this request: Set up the Plaid contribution reconciliation service with ASB Named Credentials

[Wait for Design Agent → Show plan → Get user confirmation]

Complexity Routing: Integration architecture → technical-architect

Step 3: Complex Dev Work
Use the salesforce-technical-architect subagent to: [Design's developer prompt]

Step 4: Unit Testing
Use the salesforce-unit-testing subagent to create test classes for the Apex code

Step 5: Code Review
Use the salesforce-code-review subagent to review all code created

[Wait for review verdict]

Step 6 & 7: Parallel Execution
Use the salesforce-devops subagent to deploy all components
Use the salesforce-documentation subagent to create documentation

[Summarize results]
```

---

### Skip Rules (Only When User Explicitly Requests)

| User says explicitly... | Action |
|------------------------|--------|
| "skip design" | Skip Design Agent |
| "skip tests" | Skip unit-testing agent |
| "skip review" | Skip code-review agent |
| "don't deploy" or "no deployment" | Skip devops agent |
| "no docs" or "skip documentation" | Skip documentation agent |
| "just analyze" | Only invoke Design Agent |
| "use admin not architect" | Use salesforce-admin regardless of complexity |
| "use developer not architect" | Use salesforce-developer regardless of complexity |

**If user does NOT explicitly say to skip or override → ALWAYS follow full workflow with appropriate complexity routing**

---

## Transparency & Confirmation Gates

### Gate 1: Design Confirmation
- Location: After Design Agent completes
- File: `agent-output/design-requirements.md`
- Ask: "Do you want to proceed with this plan? (yes/no/changes)"

### Gate 2: Code Review
- Location: After Code Review Agent completes
- Verdicts: APPROVED, APPROVED WITH WARNINGS, CHANGES REQUIRED
- If changes required, offer to fix via the same dev agent that built it

### Gate 3: Deployment Confirmation
- Location: Inside DevOps Agent
- Shows all components to deploy
- User chooses: All, Partial, or Cancel

---

## Project Overview

This is a Salesforce DX project named **DPEG**.

**API Version:** 67.0 (`sfdx-project.json` `sourceApiVersion`) — matches the org. LWC uplifted to 67.0 on 2026-07-18 once the Phase 8 Jest net landed; the repo is now uniformly 67.0. Sole exception: `lwc/leaseNegotiationLog` stays at 62.0 pending its in-flight feature merge.
**Package Directory:** `force-app/main/default`
**Documentation:** `docs/`
**No namespace** configured.

---

## Salesforce CLI Commands

```bash
# Authenticate to org
sf org login web --alias <alias>

# List orgs
sf org list

# Deploy specific metadata
sf project deploy start --source-dir force-app/main/default/classes/MyClass.cls

# Deploy entire project
sf project deploy start --source-dir force-app

# Run all Apex tests
sf apex run test --test-level RunLocalTests --wait 10

# Run a single test class
sf apex run test --class-names MyClassTest --wait 10

# Retrieve metadata from org
sf project retrieve start --source-dir force-app/main/default

# Open org in browser
sf org open
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
- `docs/` — Generated documentation from `salesforce-documentation` agent
- `.claude/rules/` — Enforcement rules for how metadata must be generated

---

## Application Architecture

See **@ARCHITECTURE.md** for the authoritative reference on:

- **Domain / Data Model** — object and field naming conventions, sharing defaults, record types
- **Apex Layering** — Service / Selector / Domain / Trigger-handler patterns, `TestDataFactory` usage, `WITH USER_MODE` SOQL
- **Integration / OmniStudio** — Integration Procedure, OmniScript, DataRaptor, FlexCard naming; external system boundaries
- **LWC / UI** — component hierarchy, LDS-first data access, SLDS 2 styling, testing conventions

All subagents (design / admin / developer / solution-architect / technical-architect / code-review) must consult `ARCHITECTURE.md` before producing plans or code. When a new convention is introduced, update `ARCHITECTURE.md` in the same PR.

---

## Final Reminder

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   YOU ARE THE ORCHESTRATOR.                                                   ║
║   YOUR JOB IS TO DELEGATE, NOT TO IMPLEMENT.                                  ║
║                                                                               ║
║   9-AGENT WORKFLOW:                                                           ║
║   Design → [Admin | Solution-Architect] → [Developer | Technical-Architect]  ║
║          → Unit Testing → Code Review → DevOps + Docs                        ║
║                                                                               ║
║   ROUTE BY COMPLEXITY:                                                        ║
║   Simple declarative → admin    |  Complex declarative → solution-architect  ║
║   Standard code      → developer|  Complex integration → technical-architect ║
║                                                                               ║
║   When in doubt: DELEGATE TO A SUBAGENT.                                      ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->
