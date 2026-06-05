# Fully-Local Setup Plan — docker-compose

**Date:** 2026-06-05
**Branch:** `fully-local-setup`
**Objective:** Run the entire POC locally via `docker compose` — including the
WSO2 Identity Server — with no dependency on the remote AWS VM (`13.60.190.47`)
or the WSO2 AMP AI Gateway / OTEL cloud endpoints. The only external call by
design is OpenAI (operator-supplied key).

> Status source of truth. This plan supersedes the remote-IS assumptions in
> `docs/wso2-is-setup.md` and `docs/wso2-is-rebuild-runbook.md` **for the local
> stack only**. Those remain valid for the remote VM deployment.

---

## §1 Decisions (locked 2026-06-05)

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | IS image | **`wso2/wso2is:7.3.0`** (GA, Docker Hub) | Released (not the RC the remote runs); 7.3 is the lineage the code is already tuned to (e.g. the `flowStatus=SUCCESS_COMPLETED` short-circuit in milestone-plan §0.1). Released 2026-06-02. |
| D2 | IS database | **MySQL 8 container + named volume** | Operator choice; matches the rebuild-runbook "recommended" path; survives restarts; prod-like. |
| D3 | IS config provisioning | **Automated provisioner script** (REST/SCIM/DCR) | Reproducible `up`; reuses the API surface `check-is-config.py` + `identity_server_apis/*.yaml` already speak. |
| D4 | LLM | **OpenAI direct** (operator key), AMP gateway + OTEL dropped | Operator will supply a real OpenAI key. The keyword router stays as the automatic fallback. |
| D5 | IS hostname strategy | **Single hostname `wso2is`** resolvable from both browser and containers | Avoids splitting front/back-channel URLs (no code change). See §3. |

The released image is used **as-is**; config (`deployment.toml`), the MySQL JDBC
driver, and DB schema are injected via **volume mounts** / MySQL init scripts —
WSO2's documented deployment pattern (`wso2/docker-is`). No custom IS image build.

---

## §2 Target topology

```
                        host browser (localhost)
                              │  http://localhost:8090  (SPA + login redirects)
                              │  https://wso2is:9443     (IS authorize / CIBA auth_url)   ← needs /etc/hosts: 127.0.0.1 wso2is
                              ▼
┌───────────────────────────── demo-net (bridge) ─────────────────────────────┐
│                                                                              │
│  orchestrator:8080 ──A2A──▶ hr_agent:8001 ──CIBA/MCP──▶ hr_server:8000       │
│        │     ▲           └─▶ it_agent:8002 ──CIBA/MCP──▶ it_server:8004       │
│        │     │ BCL (http://orchestrator:8080/backchannel-logout)             │
│        │     └──────────────────────────────────┐                           │
│        └─ token/authn/ciba/jwks/revoke ─────────▶│                           │
│                                                  ▼                           │
│                                            wso2is:9443  ──JDBC──▶  mysql:3306 │
│                                          (alias: wso2is)        (vol: mysql-data) │
└──────────────────────────────────────────────────────────────────────────────┘
              external (by choice): OpenAI api.openai.com  ◀── orchestrator only
```

**Removed vs remote setup:** the reverse-SSH `autossh` tunnel and the
`bcl-listener` spike service. With IS in-network, IS POSTs back-channel-logout
directly to `http://orchestrator:8080/backchannel-logout`.

---

## §3 The split-horizon hostname problem (D5)

`WSO2_IS_BASE_URL` is consumed for **both** channels (verified by source trace):

| Endpoint | Channel | Must be reachable by |
|---|---|---|
| `/oauth2/authorize` (login redirect) | **front** | browser |
| `/oidc/logout` | **front** | browser |
| CIBA `auth_url` (emitted by IS itself) | **front** | browser |
| `/oauth2/token`, `/oauth2/authn`, `/oauth2/ciba`, `/oauth2/revoke` | **back** | containers |
| `/oauth2/jwks` (`WSO2_IS_JWKS_URL`) | **back** | containers |
| `iss` claim validation (`WSO2_IS_ISSUER`) | n/a | must equal what IS emits |

A single value cannot be both `localhost:9443` (browser) and `wso2is:9443`
(containers). **Chosen fix (zero code change):** one hostname `wso2is` that
resolves to IS from both sides —

- **containers** → Docker network alias `wso2is` on the IS service (built-in DNS).
- **browser/host** → one line in `/etc/hosts`: `127.0.0.1 wso2is` (IS port published `9443:9443`).
- IS `deployment.toml` `[server] hostname = "wso2is"` → `iss`, `auth_url`,
  authorize/logout redirects are all `https://wso2is:9443/...` and consistent everywhere.
- TLS verification stays off (`IDP_INSECURE_TLS=1` / `DISABLE_SSL_VERIFY=true`),
  so the self-signed cert CN is a non-issue.

Then `WSO2_IS_BASE_URL=https://wso2is:9443`, `WSO2_IS_ISSUER=https://wso2is:9443/oauth2/token`,
`WSO2_IS_JWKS_URL=https://wso2is:9443/oauth2/jwks` for **every** service; the
orchestrator's own browser-facing URLs (`ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI`,
`POST_LOGOUT_REDIRECT_URI`) stay on `http://localhost:8090`.

`demo-up.sh` will check for the `/etc/hosts` entry and print the exact line to add if missing.

> **Fallback (not chosen):** split `WSO2_IS_BASE_URL` into a front-channel
> (browser) and an internal back-channel base URL in `common/auth` +
> `orchestrator/auth`. Removes the `/etc/hosts` step at the cost of a code change
> across shared auth. Documented here in case the hosts edit proves unacceptable.

---

## §4 Stages

Each stage produces a committable artifact and is independently runnable.

- **Stage 0 — this plan.** ✅
- **Stage 1 — Infra containers.** `mysql` + `wso2is` services in compose; MySQL
  datasource `deployment.toml`; JDBC driver + schema bootstrap via
  `scripts/local-setup.sh` (pulls the driver, extracts version-matched dbscripts
  from the image into MySQL init). Gate: IS comes up healthy against MySQL; Console
  reachable at `https://wso2is:9443/console`.
- **Stage 2 — Automated provisioner.** `scripts/provision-is.py`: idempotent
  creation of the 2 OAuth apps, 3 agents (+ backing apps, CIBA-external,
  subject=email, role-audience=Organization, API subscriptions), 2 API resources
  (8 scopes), 2 roles (scope matrix), 2 users (`username==email`), multi-attribute
  login; BCL URL `http://orchestrator:8080/backchannel-logout`; post-logout
  `http://localhost:8090/`. Writes IS-generated client IDs/secrets + agent
  UUIDs/secrets into the 5 service `.env` files. Gate: `check-is-config.py` all PASS.
- **Stage 3 — Re-point fleet + drop cloud.** App services → `wso2is:9443`;
  `LLM_FALLBACK_MODE=llm` + OpenAI-direct (`OPENAI_BASE_URL=https://api.openai.com/v1`,
  correct auth header); drop `AMP_AGENT_API_KEY` / `AMP_OTEL_ENDPOINT`; in-network
  BCL. Gate: full fleet healthy via `demo-smoke.py`.
- **Stage 4 — E2E + docs.** Sign in `employee@example.com` → UC-03 dual-specialist
  query → 2× CIBA approve → logout cascade. Update `DOCKER.md` / `README` / add a
  local runbook. Commit + push.

---

## §5 Open items to verify empirically (Stage 1–3)

1. MySQL schema bootstrap mechanism (mysql initdb-extracted dbscripts vs `-Dsetup`); chosen: mysql initdb.
2. Whether IS rejects in-network requests whose `Host: wso2is:9443` differs from a configured value (may need an allowed-hosts / proxy setting in `deployment.toml`).
3. WSO2 IS 7.3.0 GA Agents REST API shape for the provisioner (vs the 7.3.0-RC the remote runs).
4. `OpenAILLMClient` auth header for real OpenAI (`Authorization: Bearer` vs the AMP `api-key` header) — `OPENAI_API_HEADER` handling.
5. CIBA `auth_url` host: confirm IS emits `wso2is:9443` (from `[server] hostname`) so the browser (with the `/etc/hosts` entry) can open it.
