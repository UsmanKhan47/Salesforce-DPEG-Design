# Deploy verification — trust the payload, never the exit code

## `sf` exit code is unreliable on this machine (Windows / Git Bash)

Measured 2026-07-17 across 4 dry-run deploys against DPEG-Acq-5:
`sf project deploy start ... --json` returns **process exit code 1** while its own
JSON `status` field is **0 (success)**, `result.success: true`, `result.status: "Succeeded"`,
0 test errors, 0 warnings. `sf project deploy report` does the same.

**Both directions are traps:**
- exit 0 is NOT proof of a pass (a client timeout printing `Status: Pending` also exits 0)
- exit 1 is NOT proof of a failure (confirmed above)

**Verify from the payload only:**
```bash
sf project deploy start ... --json > out.json 2>&1
node -e "const d=require('C:/abs/path/out.json').result;
  console.log(d.status, d.success, d.checkOnly, d.numberTestsCompleted, d.numberTestErrors)"
```
Check `status === 'Succeeded'` && `success === true` && `numberTestErrors === 0`.
For a dry-run also assert `checkOnly === true` — that is the proof nothing really deployed.

## Gotchas hit while doing this
- `cmd | tail -N; echo $?` captures **tail's** exit code, not `sf`'s. Redirect to a file first.
- No `python` on this box. `node -e` works, but it needs **Windows-style** absolute paths
  (`C:/Users/...`); Git-Bash `/c/Users/...` fails with MODULE_NOT_FOUND.
- The CLI writes ANSI colour codes + spinner frames into redirected output. `grep "Status:"`
  will match spinner frames (`Status: \`, `Status: -`) and miss the verdict. Strip with
  `sed -e 's/\x1b\[[0-9;]*m//g'` or just use `--json`.
- Stale-source risk: the `Validated Source` table's `State` column should read `Changed`
  for files you edited. If an edited file is absent or not `Changed`, a stale zip was sent.

## Proving a test tests what it claims
A green test is not evidence the assertion is load-bearing. Mutation-test it: break the
production line the test targets, re-run, confirm **that specific test fails**, then restore
and `diff` against a pre-mutation backup to prove no residue shipped. This is cheap
(one dry-run) and is the only real defence against green-for-the-wrong-reason.
