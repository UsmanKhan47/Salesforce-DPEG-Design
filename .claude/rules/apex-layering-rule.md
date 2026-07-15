# Rule: Apex Layering Enforcement

## Objective
Enforce strict Service / Selector / Domain / Trigger-handler separation. Violations are architectural defects that compound across the codebase — catch them at generation time, not at review time.

## Layer Contract (Non-Negotiable)

| Layer | Allowed | Prohibited |
|-------|---------|-----------|
| **Trigger** | One-line delegation to handler | Any business logic, SOQL, DML |
| **TriggerHandler** | Route context to domain/service | SOQL, DML, business logic |
| **Domain** | In-memory logic on `List<SObject>` | Any SOQL, any DML |
| **Selector** | SOQL queries for one object | DML, business logic, callouts |
| **Service** | Orchestration; calls selectors + domains + UoW | Inline SOQL, inline DML outside UoW |
| **Controller** | Thin: call service, catch `AuraHandledException` | SOQL, business logic |

## Enforcement Gates

Before generating any Apex class, confirm the layer and apply its contract:

1. **Identify the layer** — what layer does this class belong to?
2. **Apply the contract** — enforce allowed/prohibited list above for that layer.
3. **Record the layer** — `layer=<trigger|handler|domain|selector|service|controller|batch|queueable>`
4. **Pre-write check** — confirm: does any generated method violate the prohibited list?

Do not generate a method that violates the layer contract. If a requirement forces a violation, stop and ask for guidance.

## SOQL Location Rule

**All SOQL must live in Selector classes.** No exceptions.

- Selector method naming: `selectByIds(Set<Id> ids)`, `selectByStatus(String status)`, etc.
- Every selector query must use `WITH USER_MODE`.
- If a service needs data, it calls the selector — it does not write its own query.
- If a domain needs data, the caller (service) passes it in — domains never query.

## Domain Purity Rule

**Domain classes contain zero SOQL and zero DML.**

- Domain methods are pure functions over `List<SObject>`: validate, derive, transform.
- Input: a collection of records. Output: mutated records or validation errors.
- If logic requires a database lookup, it belongs in the Service layer (which calls a Selector).

## TriggerHandler Base Class Rule

- Every trigger handler must extend the project's `TriggerHandler` base class (if one exists).
- The trigger file itself is one line: `new <Object>TriggerHandler().run();`
- Handler logic routes to domain methods via `override` methods — no direct DML or SOQL.

## UnitOfWork Rule

- When the project has a `UnitOfWork` class, all multi-object DML in a service method must go through it.
- Never call `insert`/`update`/`delete` directly from service methods when a UoW is available.
- `commitWork()` is called once per service method — not once per loop iteration.

## Anti-Patterns

| Don't | Do Instead |
|-------|-----------|
| SOQL inside a Service method | Move SOQL to a Selector; call the selector from the service |
| SOQL inside a Domain method | Pass queried data in from the service layer |
| DML inside a Domain method | Register on UnitOfWork from the service; domain returns mutated list |
| Business logic in a trigger | Move to TriggerHandler → Domain/Service |
| Multiple triggers per object | One trigger, one handler |
| `@future` for async | Use Queueable + `System.Finalizer` |
