# Fully-Local IS Provisioning Spec (Stage 2)

**Date:** 2026-06-05 · **Realized by:** `scripts/provision-is.py` · **Verified by:** `scripts/check-is-config.py` (32/32 PASS)

Reverse-engineered from the app code (`*/config.py`, `common/auth/*`, the CIBA /
Pattern-C flows, MCP tool scopes), the docs (`wso2-is-rebuild-runbook.md`,
`identity-subject-mismatch.md`, `scope-policy.md`, use-cases), `check-is-config.py`
(the enforced acceptance matrix), and the vendored `identity_server_apis/*.yaml`,
then **empirically validated against WSO2 IS 7.3.0 GA**. This doc is the spec the
provisioner builds to; where the released GA behaves differently from the docs
(which were written against the 7.3.0 RC + Console wizard), the **GA facts win** —
see §3.

---

## §1 Desired IS state (what the demo needs)

**API resources (2, 8 scopes):**
- `urn:hr:api` "HR API": `hr_basic_rest`, `hr_self_rest`, `hr_read_rest`, `hr_approve_rest`, `hr_assets_write_rest`
- `urn:it:api` "IT API": `it_assets_read_rest`, `it_assets_self_rest`, `it_assets_write_rest`

**Roles (Organization audience, no inheritance):**
- `employee` (lowercase): `hr_basic_rest`, `hr_self_rest`, `it_assets_read_rest`, `it_assets_self_rest`
- `HR Admin`: those 4 **+** `hr_read_rest`, `hr_approve_rest`, `hr_assets_write_rest`, `it_assets_write_rest`

**Users (`username == email`):** `employee@example.com` → `employee`; `hradmin@example.com` → `HR Admin`; both password `NewsMax@1234`, email attribute set.

**`orchestrator-mcp-client`** — confidential OIDC; grants `authorization_code`+`refresh_token`+`client_credentials`; PKCE mandatory; JWT access token 3600s; client_secret_basic; callbacks `localhost:8090/agent-callback` + `/auth/callback` + `/` (post-logout); **subject = email**; **role audience = ORGANIZATION**; **BCL = `http://orchestrator:8080/backchannel-logout`** (in-network, no tunnel); subscribed to HR(5)+IT(3).

**3 agents** — each = a **SCIM2 Agent identity** (`agent_id`+one-time `secret`) **+ a per-agent OIDC app** (`client_id`+`secret`) with **App-Native auth** enabled:
- `orchestrator-agent`: App-Native only; callback `localhost:8090/agent-callback`; no CIBA, no API subs, **no** email-subject (its `sub` must stay the agent UUID → `act.sub`).
- `hr-agent`: App-Native **+ CIBA** (expiry 300, external) **+ email-subject**; callback `localhost:9999/agent-callback`; subscribed HR(5).
- `it-agent`: same as hr-agent with IT(3).

**Server-level:** Multi-Attribute Login on `http://wso2.org/claims/emailaddress` — *not strictly required* given `username==email` (the email `login_hint` resolves directly as the username), but recommended as a fallback. Not yet automated (verify in Stage 4 E2E). UAE Pass / federated IDP steps from the old setup doc are **N/A locally**.

---

## §2 Env-var capture map (generated value → service `.env`)

| Generated value | → `.env` var (file) |
|---|---|
| orchestrator-mcp-client id/secret | `ORCHESTRATOR_MCP_CLIENT_ID`/`_SECRET` (orchestrator) |
| orchestrator-agent: agent id, secret, app id, app secret | `ORCHESTRATOR_AGENT_ID`/`_SECRET`/`_OAUTH_CLIENT_ID`/`_OAUTH_CLIENT_SECRET` (orchestrator) |
| hr/it-agent app client ids | `HR_AGENT_OAUTH_CLIENT_ID`, `IT_AGENT_OAUTH_CLIENT_ID` (orchestrator, F-15 distinctness) |
| hr+it agent UUIDs | `TRUSTED_SPECIALIST_SUBS` (orchestrator) |
| hr/it-agent: agent id, secret, app id, app secret | `*_AGENT_ID`/`_SECRET`/`_OAUTH_CLIENT_ID`/`_OAUTH_CLIENT_SECRET` (hr_agent/it_agent) |
| orchestrator-agent UUID | `HR_TRUSTED_PEER_AGENTS`, `IT_TRUSTED_PEER_AGENTS` (hr_agent/it_agent) |
| orchestrator-mcp-client id | `HR_EXPECTED_INBOUND_AUD`, `IT_EXPECTED_INBOUND_AUD` (hr_agent/it_agent) |
| hr/it-agent **app** client id | `HR_SERVER_EXPECTED_AUD`, `IT_SERVER_EXPECTED_AUD` (hr_server/it_server) — F-17 |
| hr/it-agent UUID | `HR_SERVER_TRUSTED_PEER_AGENTS`, `IT_SERVER_TRUSTED_PEER_AGENTS` (hr_server/it_server) |

Plus, into all five: `WSO2_IS_BASE_URL=https://wso2is:9443` (+ issuer/jwks/introspect), `IDP_INSECURE_TLS=1`/`DISABLE_SSL_VERIFY=true`, one shared `INTERNAL_REVOKE_SHARED_SECRET`.

---

## §3 Empirical 7.3.0-GA findings (corrections to the docs)

These were discovered by probing the live GA instance; several contradict the docs (written for the RC / Console wizard):

1. **Admin Basic auth works for all writes** — `admin:admin` Basic is accepted on POST/PUT/PATCH/DELETE across applications, api-resources, and `/scim2/*`. No OAuth bearer needed.
2. **`POST /scim2/Agents` does NOT auto-create a backing OAuth app.** The docs' "4-value" model came from the Console "Allow users to log in" wizard. Via API the correct model is: **create the SCIM2 Agent AND a standalone OIDC app with `advancedConfigurations.enableAPIBasedAuthentication=true`**; the agent then App-Native-authenticates against it (username = the **bare agent UUID**, password = the one-time agent secret). Verified: 3-step `/authorize`→`/authn`→`/token` mints a token (scope `internal_login openid`).
3. **App-create `pkce` must include `supportPlainTransformAlgorithm`** (not just `mandatory`) or IS NPEs with `APP-65006` (`OAuth2PKCEConfiguration.getSupportPlainTransformAlgorithm() is null`).
4. **CIBA config lives in the OIDC block as `cibaAuthenticationRequest`** (absent from the vendored OpenAPI): `{authReqExpiryTime: 300, notificationChannels: ["external"], skipUserValidation: false, allowFederatedUsers: false}`. Adding the CIBA grant without `authReqExpiryTime > 0` fails with *"CIBA authentication request expiry time must be greater than 0"*.
5. **`accessToken.type` defaults to `"Default"`** — set `"JWT"` explicitly (the validators require self-contained JWTs with `jti`).
6. **Subject = email** is set via the app-level `claimConfiguration.subject.claim.uri = http://wso2.org/claims/emailaddress` (PATCH `/applications/{id}`), not the OIDC `subject` block.
7. **Role audience** is read from the nested `audience: {type, value}` on `/scim2/v2/Roles` (the agent-create response uses flat `audienceValue`/`audienceType` — different shape). The **org id** (`10084a8d-…` here) is sourced from any built-in Organization-audience role (`everyone`/`system`/`admin`).
8. **Org-audience role create** = `POST /scim2/v2/Roles` with `audience.{value=<org-id>, display}`, `permissions: [{value: <scope-name>}]`, `users: [{value: <user-id>}]`. Permissions are the scope **names**.
9. **App `clientId`+`clientSecret`** are returned (cleartext) by `GET /applications/{id}/inbound-protocols/oidc` under admin auth — so creds are captured directly after create.

See `scripts/provision-is.py` for the exact request bodies and ordering (API resources → users → roles → mcp-client → agents+apps → `.env` emission). Re-runnable; reuses existing entities by name.
