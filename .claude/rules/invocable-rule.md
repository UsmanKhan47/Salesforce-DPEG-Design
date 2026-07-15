# Rule: @InvocableMethod Collection Enforcement

## Objective
Enforce that every `@InvocableMethod` uses `List` parameters and `List` return types. Non-list signatures silently break when a Flow or Apex caller passes multiple records, causing data loss or runtime errors that are hard to trace.

## The Rule

Every `@InvocableMethod` must:

1. Accept exactly **one parameter** of type `List<InputType>` — never a single object, primitive, or void.
2. Return **`List<OutputType>`** or `void` — never a single object or primitive.
3. Define `InputType` and `OutputType` as **inner classes** with `@InvocableVariable` fields.

## Correct Pattern

```apex
public with sharing class MyInvocableService {

    @InvocableMethod(label='Process Records' description='Processes a collection of records')
    public static List<OutputDTO> processRecords(List<InputDTO> inputs) {
        List<OutputDTO> results = new List<OutputDTO>();
        for (InputDTO input : inputs) {
            OutputDTO result = new OutputDTO();
            result.success = true;
            results.add(result);
        }
        return results;
    }

    public class InputDTO {
        @InvocableVariable(required=true label='Record ID')
        public Id recordId;

        @InvocableVariable(required=false label='Optional Flag')
        public Boolean flag;
    }

    public class OutputDTO {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }
}
```

## Why Collections Are Required

- Flow calls `@InvocableMethod` once per batch, passing ALL matching records as a list.
- A single-record signature receives only the first record silently — the rest are dropped.
- `List<OutputType>` return must be parallel to the input list (index i of output corresponds to index i of input).

## Enforcement Gate

Before generating any `@InvocableMethod`:

1. Confirm parameter is `List<InputType>` — not `InputType`, `String`, `Id`, or void.
2. Confirm return type is `List<OutputType>` or `void` — not a single object.
3. Confirm `InputType` inner class exists with `@InvocableVariable` fields.
4. Confirm `OutputType` inner class exists with `@InvocableVariable` fields (if returning data).

## Anti-Patterns

| Don't | Why | Do Instead |
|-------|-----|-----------|
| `public static void process(Id recordId)` | Drops all records except the first | `public static List<Output> process(List<Input> inputs)` |
| `public static MyObject process(List<Input> inputs)` | Returns only one result; rest discarded | `public static List<Output> process(List<Input> inputs)` |
| `public static List<Output> process(String name)` | String parameter, not bulk-safe | Define an `Input` DTO with `@InvocableVariable` |
| Reusing existing Apex method signature directly | Likely not List-in/List-out | Always wrap in an Invocable-specific method with DTO |
