# salesforce-developer memory

- [Deploy verification](deploy-verification.md) — `sf` exit code is unreliable both ways on this box; verify via `--json` payload (`status`/`success`/`checkOnly`/`numberTestErrors`), and mutation-test any test that claims to prove rollback
- [Platform field limits](platform-field-limits.md) — empirically measured limits (Task.Subject 255, Salesforce Date range 1700–4000) used as deliberate DML-failure levers in tests
