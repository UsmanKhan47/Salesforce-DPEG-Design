---
description: Add a new custom object (admin-only, declarative). Delegates design → admin → devops + docs.
---

# Add Custom Object

**Requested object:** $ARGUMENTS

## Flow

1. **salesforce-design** — produce the object spec (fields, relationships, sharing, record types). Display plan, get `yes/no/changes`.
2. **salesforce-admin** — generate `*.object-meta.xml` and field metadata using the `sf-custom-object` + `sf-custom-field` skills. Respect the per-type loop in `.claude/rules/salesforce-global-rule.md`.
3. **salesforce-code-review** — review metadata against `ARCHITECTURE.md` §1 (naming, sharing, relationships).
4. On approval: **salesforce-devops** + **salesforce-documentation** in parallel.
5. After devops confirms deploy, remind the user to update `ARCHITECTURE.md` §1 "Current objects" with the new object.

No Apex, no trigger, no test class for this command. If the user also wants those, tell them to use `/new-feature` instead.
