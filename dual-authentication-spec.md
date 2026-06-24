# Specification: Dual Authentication (User OBO + Machine App-Only)

> Status: Approved design, ready for implementation.
> Scope: Add machine-to-machine authentication to the Azure Databricks Jobs MCP
> server while preserving the existing per-user On-Behalf-Of (OBO) flow.

## 1. Summary

The MCP server currently authenticates **users** and calls Databricks **as the user**
via the OAuth 2.0 On-Behalf-Of (OBO) flow. This specification adds a second,
parallel authentication path so that a **Service Principal (SP) or Managed Identity
(MI)** can call the MCP server autonomously (e.g. to poll job status and run analysis).

Two inbound token shapes are supported:

| Path | Inbound token | Authorized by | Outbound call to Databricks |
|------|---------------|---------------|-----------------------------|
| **User (delegated)** — existing | Entra delegated token (`scp` contains `jobs`) | Delegated scope consent | OBO exchange — acts **as the user** |
| **Machine (app-only)** — new | Entra app-only token (`roles` contains an app role) | Entra **App Role** assignment + admin consent | Client-credentials — acts **as the MCP server's own SP** |

## 2. Background / Constraints

- **OBO requires a user.** An app-only (client-credentials) token has no user
  principal, so the OBO flow cannot be used for the machine path. The machine path
  must mint a **fresh** Databricks-audience token using the MCP server's own
  confidential-client credentials (`acquire_token_for_client`).
- **FastMCP `JWTVerifier` reads only `scope`/`scp`, never `roles`.** With the current
  `required_scopes=["jobs"]`, an app-only token (which has no `scp`) is **rejected**.
  The verifier must be adjusted to accept app-only tokens that carry a recognized
  **app role**.
- **Full claims are available downstream.** `AccessToken.claims` preserves the entire
  decoded JWT (`roles`, `idtyp`, `scp`, `oid`, ...), enabling per-request branching.
- **Confidential client already exists.** `DatabricksTokenProvider` already builds an
  MSAL `ConfidentialClientApplication` (client secret or managed-identity federated
  credential). The machine path reuses it — **no new credential configuration**.

## 3. Design Decisions

1. **Separate app roles.** Read tools require `Jobs.Read`; `run_now` additionally
   requires `Jobs.Run`. This isolates the only state-changing operation.
2. **Outbound machine identity = the app-registration SP** (via MSAL
   `acquire_token_for_client`). All machine callers act as this single Databricks
   identity. One Databricks service principal to grant.
3. **No feature flag.** App-only tokens are accepted whenever they carry a recognized
   app role. Security rests entirely on **App Role assignment + admin consent**; no app
   role is assigned to any caller by default.

## 4. Authorization Model

### 4.1 Inbound central gate (verifier)

After signature/issuer/audience validation succeeds, accept the token **iff**:

- **Delegated:** `scp`/`scope` contains **all** required delegated scopes
  (e.g. `jobs`); **or**
- **Machine:** `roles` contains **at least one** known app role
  (`Jobs.Read` or `Jobs.Run`).

If **neither** condition holds, the verifier **must reject** the token (return `None`).
There is no silent-accept path.

### 4.2 Per-tool enforcement (tools layer)

- **Delegated caller:** no extra role check — Databricks authorizes the user via OBO.
- **Machine caller:** the tool's **specific** app role must be present in `roles`:
  - `list_jobs`, `list_runs`, `get_run`, `get_run_output` -> require `Jobs.Read`.
  - `run_now` -> require `Jobs.Run`.
  - Missing role -> authorization error (do **not** call Databricks).

### 4.3 Principal detection

A token is treated as **machine (app-only)** when:

- `idtyp == "app"`, **or**
- `scp`/`scope` is absent **and** `roles` is present.

Otherwise it is treated as **delegated (user)**.

## 5. Detailed Changes

### 5.1 `src/databricks_jobs_mcp/config.py`

- Add settings:
  - `mcp_machine_read_role: str = "Jobs.Read"`
  - `mcp_machine_run_role: str = "Jobs.Run"`
- Add property:
  - `known_app_roles -> list[str]` returning `[mcp_machine_read_role, mcp_machine_run_role]`.
- No new credential settings (outbound reuses the existing confidential client).

### 5.2 `src/databricks_jobs_mcp/auth.py`

- Add method `DatabricksTokenProvider.token_for_service_principal() -> str`:
  - Under `self._lock`, call `self._get_app().acquire_token_for_client(scopes=[DATABRICKS_SCOPE])`.
  - On missing `access_token`, raise an error consistent with `OboError`
    (reuse `OboError` or introduce a shared `TokenError` base).
  - MSAL caches the app token internally; no extra caching required.
- Leave `token_for_user` unchanged.

### 5.3 `src/databricks_jobs_mcp/server.py`

- Construct `JWTVerifier`/`DiagnosticJWTVerifier` with `required_scopes=None`
  (move the gate into the override so app-only tokens are not auto-rejected for the
  missing `scp`).
- Pass `Settings` into `DiagnosticJWTVerifier` (constructor) so it knows the required
  delegated scopes and `known_app_roles`.
- Extend `DiagnosticJWTVerifier.verify_token`:
  - Call `super().verify_token(token)`.
  - If `None` -> keep existing DEBUG diagnostics, return `None`.
  - Else apply section 4.1 gate using `result.claims`. If neither condition holds, log at
    DEBUG and return `None`.
- Thread `settings` into `register_tools`.

### 5.4 `src/databricks_jobs_mcp/tools.py`

- Add `_principal_is_app(claims: dict) -> bool` per section 4.3.
- Replace `_databricks_token()` with `_authorize(required_app_role: str) -> str`:
  1. `token = get_access_token()`; if `None`/empty -> authentication error.
  2. If delegated -> `return token_provider.token_for_user(token.token)`.
  3. If machine -> verify `required_app_role in (token.claims.get("roles") or [])`;
     if missing -> authorization error; else
     `return token_provider.token_for_service_principal()`.
- Update each tool to call `_authorize` with the correct role:
  - read tools -> `settings.mcp_machine_read_role`
  - `run_now` -> `settings.mcp_machine_run_role`
- `register_tools` gains a `settings` (or the two role names) parameter.

## 6. Entra App Registration Setup

1. **App roles** (Manifest / "App roles" blade), `allowedMemberTypes: ["Application"]`:
   - `Jobs.Read` — required for read tools.
   - `Jobs.Run` — required for `run_now`.
2. **Assign roles** to the calling SP/MI under the Enterprise Application
   (or via Microsoft Graph `appRoleAssignments`) and **grant admin consent**.
   - Assign `Jobs.Read` to read-only machine callers.
   - Assign **both** `Jobs.Read` and `Jobs.Run` to callers allowed to trigger runs.
3. **No role is assigned by default** — only explicitly granted principals can call.

## 7. Databricks Workspace Setup

- Add the **MCP app-registration service principal** to the Databricks workspace.
- Grant **least privilege**:
  - Read permissions on the relevant jobs (for read tools).
  - "Can Run" on specific jobs only where `run_now` is intended.
- Note: All machine callers share this one Databricks identity; Databricks audit logs
  attribute machine calls to the MCP SP, not the individual calling SP.

## 8. Security Considerations

- **Shared Databricks identity.** All machine callers act as the single MCP SP. Apply
  least privilege; isolate the only write operation (`run_now`) behind `Jobs.Run`.
- **App-only tokens never use OBO.** Explicit branch prevents passing an app token where
  a user assertion is expected.
- **No token forwarding.** The inbound token is never sent to Databricks; a fresh token
  is always minted. Combined with the strict audience check (`api://<client_id>` /
  client_id), this avoids confused-deputy risk.
- **No feature flag => assignment is the only control.** No app role is assigned by
  default; tightly control App Role assignments and admin consent.
- **Fail closed.** The verifier override must reject any token that has neither a
  required delegated scope nor a known app role.

## 9. Verification

### 9.1 Unit tests

- Verifier accepts delegated token (`scp=jobs`).
- Verifier accepts app-only token (`roles=["Jobs.Read"]`).
- Verifier rejects app-only token with no role or an unknown role.
- Verifier rejects a token with neither required scope nor known role.
- `_principal_is_app`: true for `idtyp=app` and for roles-only; false for `scp`-only.
- `run_now` machine path: without `Jobs.Run` -> authorization error; with `Jobs.Run` ->
  calls `token_for_service_principal`.
- Read tool machine path: with `Jobs.Read` -> calls `token_for_service_principal`.

### 9.2 Manual / integration

- SP with `Jobs.Read` calls `list_jobs` -> success; `run_now` -> blocked until `Jobs.Run`
  is granted.
- Existing user OBO path unchanged (regression check on all tools).

## 10. Out of Scope

- Per-machine-caller Databricks identities (all machines share the MCP SP).
- Changes to the user/OBO flow behavior.
- New transport, tools, or Databricks endpoints.
- Dynamic Client Registration or any change to client onboarding.
