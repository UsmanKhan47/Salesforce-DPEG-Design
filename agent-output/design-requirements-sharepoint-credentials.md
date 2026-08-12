# Design Requirements — SharePoint / Microsoft Graph credential scaffolding

Date: 2026-08-10
Design agent output. Gate 1 document — read the three DECISIONS in §2 before approving.

---

## 1. WHAT THE USER REQUESTED

Salesforce-side credential scaffolding only, as source-controlled metadata, so it can be deployed
and the secret entered by hand afterwards. Microsoft-side setup (Entra app registration) is already
done by the user.

Verbatim scope statement: *"just create these external credential and named credential and just tell
me where to put the keys and other stuff I will manually place them"*.

Four deliverables:

1. `ExternalCredential` metadata file — principal defined, **no secret**.
2. `NamedCredential` metadata file.
3. A permission set granting External Credential Principal Access.
4. Precise post-deploy manual instructions: which fields, filled where.

Target configuration as given:

| Item | Value |
| --- | --- |
| External Credential label | SharePoint |
| Protocol | OAuth 2.0 |
| Flow type | Client Credentials with Client Secret |
| Identity Provider URL | `https://login.microsoftonline.com/67d61826-1e02-XXXX-XXXX-XXXXXXXXXXXX/oauth2/v2.0/token` (user holds the full tenant GUID) |
| Scope | `https://graph.microsoft.com/.default` |
| Principal | Client ID `1d572fdf-ab40-4a45-ba61-97243274b6ee` + client secret |
| Named Credential label | SharePoint |
| Named Credential URL | `https://graph.microsoft.com/v1.0` |
| External Credential link | SharePoint |
| Generate Authorization Header | checked |
| Permission set | External Credential Principal Access → running user |
| Verification | anonymous Apex `GET callout:SharePoint/sites/avanzagroup.sharepoint.com,3069d658-…,db840233-…` |

**NOT in scope** (user mentioned only as background): the "create a SharePoint folder when an
Opportunity hits Closed Won" feature. See §9.

---

## 2. DECISIONS REQUIRED BEFORE IMPLEMENTATION

### 🔴 D1 — This is a SECOND deliberate exception to ARCHITECTURE.md §3.1. The user must acknowledge it.

`ARCHITECTURE.md` §3.1 is unambiguous:

> **All external integrations route through ASB. No direct peer-to-peer integrations between
> Salesforce and external systems.** Salesforce holds a **single Named Credential pointing to the
> ASB endpoint only** — not to Plaid, Yardi, CoStar, or any external system directly.

§3.3 records exactly **one** standing exception: the direct OpenAI callout for Broker Protection,
justified as *"no ASB LLM-extraction spoke exists yet, so there is nothing on the bus to route to"*,
and explicitly framed as **temporary, scoped and reversible**.

A Named Credential pointing at `https://graph.microsoft.com/v1.0` is a **direct peer-to-peer
integration with Microsoft Graph** and would be the **second** exception. This is not a technical
blocker — the metadata deploys fine — it is a governance decision that only the user can take. Three
options:

| Option | What it means | Cost |
| --- | --- | --- |
| **A — Proceed as a documented §3.4 exception** (what the user asked for) | Build exactly the spec. Add a §3.3-style justification block to ARCHITECTURE.md in the same PR (§6 requires it). | One more direct-callout surface; credential rotation now lives in two places (ASB vault + Salesforce Setup). |
| **B — Route Graph through ASB** | ASB holds the Entra client secret; Salesforce keeps one NC pointing at ASB. | Conformant, but requires an ASB SharePoint spoke that does not exist today, and blocks the user's immediate goal. |
| **C — Proceed as a time-boxed spike** | Same as A, but the justification block states an explicit retirement condition ("retire when ASB exposes a SharePoint/Graph spoke"). | Same as A; the honest framing if this is exploratory. |

**Recommendation: A or C.** The user has already done the Entra registration and asked only for
scaffolding; blocking on ASB would discard that work. But the exception must be written down, not
inherited silently — §3.3 exists precisely because the OpenAI exception was argued and recorded
rather than assumed. Draft justification text is in §7 below.

> ⚠ Note the asymmetry with OpenAI: the §3.3 exception rests on *"no ASB spoke exists yet"*. That
> same sentence is true for SharePoint today, so the argument transfers — but it transfers as an
> argument that must be **restated**, not as a precedent that pre-approves anything. This is the
> second time; a third should trigger a review of whether §3.1 still describes reality.

### D2 — The full Tenant ID

The Identity Provider URL is **deployable, non-secret metadata**, but the user's spec redacts the
tenant GUID (`67d61826-1e02-XXXX-XXXX-XXXXXXXXXXXX`). Choose one:

- **D2a (recommended):** user supplies the full GUID now → it ships complete in the file, deploy is
  final, nothing to hand-edit.
- **D2b:** ship the placeholder → **the user must edit the file before deploying**, or the deploy
  produces a credential that will fail token acquisition with an opaque Azure error. If D2b is
  chosen, the placeholder must be obviously invalid (e.g. `REPLACE_ME_TENANT_ID`), never the
  `XXXX`-masked form, which looks plausible enough to deploy by accident.

### D3 — Developer names (label ≠ API name)

The user gave **labels**, not API names. The API names are what everything else binds to.

| Component | Proposed developer name | Why |
| --- | --- | --- |
| Named Credential | **`SharePoint`** | 🔴 **Pinned, not chosen** — the smoke test calls `callout:SharePoint/...`. Any other name breaks it. |
| External Credential | **`SharePoint_Credential`** | Matches the repo precedent `OpenAI_Credential`. Label stays "SharePoint" as requested. Referenced only by the NC and the permission set — no Apex pins it. |
| Principal | **`SharePoint_Principal`** | Matches `OpenAI_Principal`. |
| Permission set | **`SharePoint_Integration_Access`** | New layer-4 capability set (see D4). |

Permission-set principal reference string: `SharePoint_Credential-SharePoint_Principal`
(same `<EC>-<Principal>` form as the deployed `OpenAI_Credential-OpenAI_Principal`).

### D4 — New permission set, not an amendment (recommended)

The parent request allowed "or an amendment to an existing one". **Create a new one.** Reasons:

- `ARCHITECTURE.md` §2 → *Permission Set Architecture* defines exactly this as a **layer 4
  capability set**: the grants a named feature needs, nothing else. `Broker_Protection_Access` is
  the direct precedent, and it is OpenAI-specific — SharePoint does not belong in it.
- 🔴 It sidesteps the repo's sharpest permission-set hazard entirely. A `PermissionSet` deploy
  **REPLACES** its whole grant set rather than merging; amending an existing live set requires
  reconciling repo↔org first, and this repo has paid for that twice (2026-08-05 and 2026-08-06, the
  wiped `Task.WhoId` grant that broke the live inbound pipeline). A brand-new file has nothing to
  wipe.

If the user overrides and wants an amendment, the reconcile-against-org step becomes **mandatory and
blocking**, not advisory.

---

## 3. 🔵 ADMIN WORK (salesforce-admin)

No dev work in this request — see §4.

### A1. `force-app/main/default/externalCredentials/SharePoint_Credential.externalCredential-meta.xml`

Functional requirements:

- Label: `SharePoint`
- Authentication protocol: **OAuth 2.0**, flow **Client Credentials with Client Secret**
- Token / Identity Provider URL: `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token`
- Scope: `https://graph.microsoft.com/.default`
- One **Named Principal** named `SharePoint_Principal`, `sequenceNumber` 1
- Client ID `1d572fdf-ab40-4a45-ba61-97243274b6ee` — **deployable** (a public identifier, not a
  secret). Ship it in the file.
- **Client secret — ABSENT. Not deployable under any circumstance.** See §6.
- `<description>` following the `OpenAI_Credential` precedent, stating that the secret lives in the
  principal's authentication parameter, entered in Setup post-deploy, and is never serialized into
  metadata or source control.

🔴 **The in-repo precedent does NOT cover this file's auth block, and the admin agent must not
assume it does.** `OpenAI_Credential` uses `<authenticationProtocol>Custom</authenticationProtocol>`
with a `NamedPrincipal` + an `AuthHeader` parameter carrying a `Bearer {!$Credential…}` merge field.
That is a **different protocol** with a different parameter shape. The `sf-integration` skill's only
worked `ExternalCredential` XML example is the same `Custom` shape — it has no OAuth
client-credentials example either. So:

> **Mandatory for the admin agent:** resolve the exact `ExternalCredential` element and parameter
> names for OAuth / client-credentials at **API 67.0** via the `salesforce-api-context` MCP
> (`get_metadata_type_fields` / `get_metadata_type_context` for `ExternalCredential`) **before
> writing**, per `.claude/rules/salesforce-global-rule.md`. Do **not** infer them from
> `OpenAI_Credential.externalCredential-meta.xml`. What the precedent DOES govern here is file
> location, naming, indentation, and the `<description>` convention — not the auth block.

**Fallback if the OAuth client-credentials shape cannot be expressed reliably in metadata at 67.0:**
create the External Credential **by hand in Setup** (it is a 2-minute UI task the user is already
prepared to do), deploy only A2 + A3, and record that decision in the doc. Do not ship a guessed
file — a malformed External Credential fails at token-acquisition time with an opaque Azure error,
which is exactly the class of failure this repo has been burned by before.

### A2. `force-app/main/default/namedCredentials/SharePoint.namedCredential-meta.xml`

- Label: `SharePoint`
- `namedCredentialType`: `SecuredEndpoint`
- `calloutStatus`: `Enabled`
- URL parameter: `https://graph.microsoft.com/v1.0`
- Authentication parameter → `externalCredential` = `SharePoint_Credential`
- 🔴 **`generateAuthorizationHeader` = `true`** — as the user specified, and required: with OAuth
  client credentials the *platform* mints `Authorization: Bearer <token>` from the External
  Credential. **DO NOT copy `false` from `OpenAI_API.namedCredential-meta.xml`.** That file sets it
  `false` and carries a load-bearing comment explaining why (its External Credential supplies its own
  custom `Authorization` header, and `true` overrode it and broke every callout, found live
  2026-08-01). Same field, opposite correct value, for opposite reasons. Copying the precedent here
  would break every SharePoint callout.
- `allowMergeFieldsInHeader` / `allowMergeFieldsInBody`: **`false` / `false`**. OpenAI sets the
  header flag `true` only because it uses a merge-field header; SharePoint uses none, so leaving it
  false is the minimum-surface choice. (If the admin agent finds the platform requires otherwise at
  67.0, follow the platform and note it.)

### A3. `force-app/main/default/permissionsets/SharePoint_Integration_Access.permissionset-meta.xml`

New file. Contents, in full — nothing else:

- `<label>SharePoint Integration Access</label>`, `<hasActivationRequired>false</hasActivationRequired>`,
  no `<license>` (matches every DPEG-authored set in this repo).
- `<description>` — one line, **≤ 255 characters** (hard platform cap; exceeding it is what made
  `Broker_Protection_Access` undeployable on 2026-08-03). Anything longer goes in an XML comment
  **inside** the root element, never above it.
- `externalCredentialPrincipalAccesses` → `enabled` true,
  `externalCredentialPrincipal` = `SharePoint_Credential-SharePoint_Principal`.
- `objectPermissions` → **`UserExternalCredential`, read only** (`allowRead` true, everything else
  false).

> ⚠ On that last item: it is **precedent-required, not scope creep.** `Broker_Protection_Access`
> carries the identical grant with an in-file comment — *"Required to USE the OpenAI Named
> Credential — without object read on `UserExternalCredential` the callout throws before sending
> (found via debug log 2026-08-01)"* — and its long-form comment repeats it as a standing
> requirement. Omitting it reproduces a failure this org has already measured. If the user
> disagrees, drop it and expect the smoke test to fail before the request leaves the org.
>
> **No `fieldPermissions`, no `classAccesses`.** There is no Apex in this request. Keeping the file
> at zero field permissions also means the REPLACE-not-merge hazard has nothing to destroy.

### A4. `ARCHITECTURE.md` — new §3.4 exception block (only if D1 = A or C)

Required by `ARCHITECTURE.md` §6: *"When an external integration is wired, document it under §3
Integration Architecture"*, in the same PR. Draft text in §7 below. This is a rule-driven
obligation, not an addition to the user's scope.

---

## 4. 🟢 DEVELOPMENT WORK (salesforce-developer)

**None.** The user explicitly scoped this to credential scaffolding.

The smoke test in the spec is **anonymous Apex run once by hand** (§8, step 5) — it is a verification
step, not a class to author. No `SharePointCalloutService`, no `HttpCalloutMock`, no test class is in
scope. Those belong to the deferred follow-on feature in §9, where §2's *"all ASB/Plaid callouts
wrapped in a dedicated service class so they can be mocked"* standard will apply.

---

## 5. 🔗 EXECUTION ORDER

1. **User answers D1–D4.** D1 is a governance acknowledgement; D2 is a value the design cannot
   invent; D3/D4 have recommended defaults that only need a nod.
2. **A1 External Credential** — must exist before A2 can reference it, and before A3 can name its
   principal.
3. **A2 Named Credential** — references A1.
4. **A3 Permission set** — references A1's principal.
5. **A4 ARCHITECTURE.md §3.4** — same PR as 2–4.
6. **Deploy** (devops agent). ⚠ Deploy-path check: `manifest/package.xml` currently lists **neither**
   `NamedCredential` nor `ExternalCredential` as a type, and the existing OpenAI pair is not in it
   either — so these deploy via `--source-dir`, not via the manifest. If the team deploys by
   manifest, both types must be added there or the files silently do not ship.
7. **Manual post-deploy steps** — §8. Nothing works until step 5.1 (the secret) and 5.3 (the
   assignment) are done by hand.

---

## 6. 🔴 THE SECRET IS NOT DEPLOYABLE — UNMISTAKABLY

The Entra **client secret** cannot be, and must never be, in this repo.

- Salesforce stores authentication-parameter values **encrypted** and does not serialize them into
  retrieved metadata. There is no XML element that carries it. A "deployable secret" does not exist
  for this credential type.
- It is entered **once, by hand, in Setup**, after deploy (§8 step 1).
- A `sf project retrieve` of this External Credential will **not** bring the secret back — the file
  in source control stays secret-free by construction. If a retrieve ever produces something that
  looks like a secret, stop and treat it as an incident.
- The **Client ID** (`1d572fdf-…`) is *not* a secret — it is a public application identifier and
  ships in the file. Do not conflate the two.
- Precedent: `OpenAI_Credential`'s own `<description>` says the same thing in the same words — *"the
  key lives in the … authentication parameter, entered in Setup post-deploy and never serialized
  into metadata or source control"*, and §3.3 repeats it. This is the established pattern in this
  org, not a new rule.

---

## 7. DRAFT §3.4 JUSTIFICATION BLOCK (for ARCHITECTURE.md, if D1 = A or C)

Written in the voice and shape of the existing §3.3. The admin/documentation agent should adjust the
retirement condition to match whichever of D1-A / D1-C the user picks.

> ### 3.4 Deliberate, Temporary Exception — Direct Microsoft Graph Callout (SharePoint)
>
> Salesforce holds a `SharePoint` Named Credential pointing **directly** at
> `https://graph.microsoft.com/v1.0`, authenticated by the `SharePoint_Credential` External
> Credential (OAuth 2.0, client-credentials flow, Entra app registration in the DPEG tenant). This
> bypasses §3.1's ASB-only rule and is the **second** such exception after §3.3.
>
> **Why:** no ASB SharePoint/Graph spoke exists, so there is nothing on the bus to route to — the
> same condition that justified §3.3. Document storage for the acquisitions deal tree is a
> first-party Microsoft 365 tenant DPEG already owns and administers, so no third-party secret is
> being spread across systems: the only credential involved is DPEG's own Entra client secret.
>
> **Scope and reversibility:** the exception is confined to one Named Credential and one External
> Credential. Retiring it means repointing the Named Credential's URL at the ASB spoke and moving
> the client secret into ASB's secrets vault; no Apex signature changes, because every callout goes
> through `callout:SharePoint/...`. **Retire this exception when ASB exposes a SharePoint/Graph
> spoke.**
>
> **Credentials are never hardcoded.** The client secret lives entirely in the
> `SharePoint_Credential` External Credential's `SharePoint_Principal` authentication parameter,
> entered in Setup **post-deploy**, and is never serialized into metadata or source control. The
> client ID and the Entra tenant's token endpoint are public identifiers and are in source.
>
> **Access:** granted by the `SharePoint_Integration_Access` permission set (External Credential
> Principal Access + `UserExternalCredential` read). ⚠ `PermissionSetAssignment` is not deployable
> metadata — assignment is an in-org step and is not represented in this repo.
>
> ⚠ **This is the second direct-callout exception.** §3.1 still describes the intended architecture,
> but two standing exceptions is the point at which a third should trigger a review of whether the
> rule or the reality needs to change, rather than another exception block.

---

## 8. POST-DEPLOY MANUAL STEPS — EXACTLY WHERE TO PUT WHAT

Everything below is **in-org and not deployable**. Nothing in §3 works until steps 1 and 3 are done.

| # | Where | What to enter | Why it is manual |
| --- | --- | --- | --- |
| 1 | **Setup → Named Credentials → External Credentials tab → `SharePoint` → Principals → `SharePoint_Principal` → Edit** | **Client Secret** = the Entra client secret **value** (not the secret ID). Confirm **Client ID** reads `1d572fdf-ab40-4a45-ba61-97243274b6ee`. Save. | Encrypted authentication parameters are never serialized into metadata. This is the only place the secret can go. |
| 2 | Same screen (External Credential detail) | Verify **Identity Provider URL** contains the **real tenant GUID**, not a placeholder, and that **Scope** reads `https://graph.microsoft.com/.default`. | Only needed if D2b (placeholder) was chosen. Wrong tenant = opaque Azure token failure. |
| 3 | **Setup → Permission Sets → `SharePoint Integration Access` → Manage Assignments → Add Assignment** → the running user | The user who will execute the callout (for the smoke test: yourself). | `PermissionSetAssignment` is not deployable metadata — a repo-wide constraint, not a SharePoint one. |
| 4 | Same permission set → **External Credential Principal Access** | Confirm `SharePoint_Credential - SharePoint_Principal` is listed and enabled. | Read-back verification. A green deploy is not proof; this repo has been burned by permission-set deploys that silently dropped grants. |
| 5 | **Setup → Developer Console → Debug → Open Execute Anonymous Window** | Paste and run the spec's smoke test verbatim (below). Expect HTTP **200** with a JSON site body. | End-to-end proof: token acquisition + header injection + principal access all at once. |

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:SharePoint/sites/avanzagroup.sharepoint.com,3069d658-a975-4a9e-ab31-86248f0c36b3,db840233-7442-4207-9f8d-4db7cef6df9e');
req.setMethod('GET');
HttpResponse res = new Http().send(req);
System.debug(res.getStatusCode());
System.debug(res.getBody());
```

**Reading the smoke-test result:**

| Result | Most likely cause |
| --- | --- |
| `200` + site JSON | Working. Done. |
| Exception naming the Named Credential / "no access" before any HTTP status | Step 3 or 4 missed — permission set not assigned, or `UserExternalCredential` read missing (§3 A3). |
| `401` from Graph | Secret wrong/expired, or `generateAuthorizationHeader` is `false` (see §3 A2 — the one field where copying the OpenAI precedent is wrong). |
| `403` from Graph | Token acquired but the Entra app lacks the Graph application permission / admin consent — Microsoft side, outside this scope. |
| Token-endpoint / tenant error before Graph is reached | Tenant GUID or scope wrong (step 2). |

⚠ No Remote Site Setting or CSP Trusted Site is required — Named Credential callouts and the
platform's own token request are both exempt.

---

## 9. EXPLICITLY OUT OF SCOPE (noted as follow-on only)

**"Create a SharePoint folder when an Opportunity hits Closed Won"** — mentioned by the user as
background context only; **not designed here**. When it is requested, it becomes a separate design
pass, and at least these will need deciding:

- The callout must be wrapped in a dedicated, mockable service class (`ARCHITECTURE.md` §2
  *Standards* → Callouts), with `HttpCalloutMock` coverage.
- 🔴 **`Closed Won` already has two routes** — `StageAdvanceService.NEXT_STAGE` maps both
  `PSA ⇒ Closed Won` and `About to Close ⇒ Closed Won`, and Tranche 5A's `PropertyAssetService` was
  put on the Opportunity trigger's stage-entry path for exactly that reason. Anything keyed to "the
  flow that already fires there" would miss half of all closes, invisibly.
- Callouts cannot be made from a trigger synchronously; this is Queueable/async work with its own
  failure-recording question.

None of that is being decided now.

---

## 10. RESIDUAL RISKS

1. **The OAuth `ExternalCredential` XML shape is unverified in this repo.** No precedent, no skill
   example. If MCP cannot confirm it at 67.0, take the §3 A1 fallback (build the EC by hand in
   Setup) rather than guessing.
2. **Deploying an OAuth External Credential with no secret is expected to succeed** and leave the
   principal in an unconfigured state — but that has not been verified in this org. Treat the §8
   step 1 screen actually offering a Client Secret field as the confirmation.
3. **D1 unanswered = the change ships against a documented architecture rule** with no record of the
   decision. That is the single worst outcome here, and it is silent.
4. **Assignment and secret entry are in-org and invisible to source control**, so a fresh org / a
   teammate's environment will have a deployed-but-dead credential with no signal. §8 is the runbook
   that fixes that; it should be linked from the §3.4 block.
