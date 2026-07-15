---
description: Add a trigger using the handler pattern, with tests, review, and deploy.
---

# Add Trigger

**Target object + events:** $ARGUMENTS

## Flow

1. **salesforce-design** — clarify events (before/after, insert/update/delete/undelete), business rules, and which domain method(s) should handle them.
2. **salesforce-developer** — generate:
   - `<Object>Trigger.trigger` — thin, delegates only
   - `<Object>TriggerHandler.cls` — routes events
   - `<Object>Domain.cls` — business rules
   Must follow `ARCHITECTURE.md` §2 Apex Layering. Use templates from `.claude/skills/sf-apex/assets/`.
3. **salesforce-unit-testing** — create tests with bulk assertions (251+ records) using `TestDataFactory`.
4. **salesforce-code-review** — focus on bulkification, no SOQL/DML in loops, `WITH USER_MODE`, `with sharing`.
5. **salesforce-devops** + **salesforce-documentation** in parallel.

If the target object doesn't exist yet, stop and tell the user to run `/add-object` first.
