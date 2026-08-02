---
name: deploy-verification
description: How to verify a Salesforce deploy actually succeeded on this box — sf exit codes and "Pending" output are both unreliable signals
metadata:
  type: feedback
---

Never claim a deploy succeeded based on the shell exit code or on truncated CLI output. Confirm from the JSON payload AND the server-side deploy report (deploy ID + component count + test numbers).

**Why:** two observed failure modes on this machine (reported by the developer agent during the 2026-07-17 Lease Inquiry deploy):

1. `sf` exits 1 even when its own JSON reports `status: 0` / `success: true`. The exit code is unreliable in **both** directions — a 0 does not prove success either.
2. A client-side timeout prints `Status: Pending` with **0 components**. This is not a successful deploy; the server may still be running, may have failed, or may never have started.

**How to apply:** after any deploy or validation, read the deploy ID out of the JSON and pull the server-side report before reporting an outcome. Report the actual deploy ID, status, and test pass/fail counts from the server — never from the shell's framing. If you cannot reach the server-side report, say the outcome is unknown rather than inferring it.
