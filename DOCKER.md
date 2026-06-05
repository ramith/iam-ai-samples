# Docker Deployment (fully-local)

Run the **entire** stack with Docker Compose — including the WSO2 Identity
Server and its MySQL backing store. Nothing depends on the remote AWS VM. The
only call that leaves your machine is the LLM, which goes through the **WSO2
Agent Manager (SaaS) AI Gateway** (OpenAI-compatible).

> Branch `fully-local-setup` is maintained as a standalone local demo/deployment
> mode. See **`docs/architecture/fully-local-setup-plan.md`** for the design and
> **`docs/architecture/fully-local-is-provisioning-spec.md`** for the IS config.

## Topology

**Infra tier:**

| Service  | Image / port | Role |
|----------|--------------|------|
| `mysql`  | `mysql:8.0` (internal 3306) | WSO2 IS backing store (named volume `mysql-data`, latin1). |
| `wso2is` | `wso2/wso2is:7.3.0` · `9443:9443` | Identity Server (network alias `wso2is`). Config + JDBC driver mounted in; schema loaded by MySQL init. Configured by `scripts/provision-is.py`. |

**App tier:**

| Service        | Container port | Host publish              | Role |
|----------------|----------------|---------------------------|------|
| `orchestrator` | 8080           | `8090:8080`               | SPA host + BFF + A2A client + LLM router/composer + back-channel-logout receiver. `8090` is user-facing. IS posts BCL **in-network** to `orchestrator:8080/backchannel-logout` (no tunnel). |
| `hr_agent`     | 8001           | `127.0.0.1:8001:8001`     | HR specialist agent; per-agent CIBA → `hr_server` MCP tools. |
| `it_agent`     | 8002           | `127.0.0.1:8002:8002`     | IT specialist agent; per-agent CIBA → `it_server` MCP tools. |
| `hr_server`    | 8000           | `127.0.0.1:8000:8000`     | HR MCP tools + REST. Loopback-only. |
| `it_server`    | 8004           | `127.0.0.1:8004:8004`     | IT MCP tools + REST. Loopback-only. |

External (by design): the **WSO2 Agent Manager AI Gateway** for the LLM
(`OPENAI_BASE_URL` / `OPENAI_API_KEY` with the `api-key` header in `orchestrator/.env`).

## Prerequisites

- Docker + Docker Compose v2 (`docker compose version` → v2.x)
- Python 3 (for `scripts/local-setup.sh`, `scripts/provision-is.py`, smoke scripts)
- A **one-time `/etc/hosts` entry** so the browser can resolve the IS hostname
  (the issuer + CIBA `auth_url` + login redirects are all `https://wso2is:9443`):

  ```bash
  echo "127.0.0.1 wso2is" | sudo tee -a /etc/hosts
  ```

The five service `.env` files are **generated** by `scripts/provision-is.py` — you
do not hand-edit them. (Copy from `*.env.example` only if running a service
outside compose.)

## Quick Start

```bash
# 1. one-time: fetch the MySQL JDBC driver + extract the version-matched WSO2 schema
./scripts/local-setup.sh

# 2. bring up the infra tier (MySQL + WSO2 IS)
docker compose up -d mysql wso2is
docker compose logs -f wso2is        # wait for "WSO2 Carbon started"

# 3. configure IS for the demo + write the five service .env files
#    (reuses your shell OPENAI_BASE_URL/OPENAI_API_KEY for the AI-gateway LLM)
OPENAI_BASE_URL=<wso2-agent-manager-gateway-url> OPENAI_API_KEY=<gateway-key> \
  python3 scripts/provision-is.py

# 4. verify the IS config (expect 32/32 PASS)
IS_BASE_URL=https://localhost:9443 ./scripts/check-is-config.py

# 5. build + start the app fleet
docker compose up -d --build
python3 scripts/demo-smoke.py        # healthz across the app services
```

Then open **http://localhost:8090** and sign in as a demo user
(`employee@example.com` / `hradmin@example.com`, password `NewsMax@1234`).

> **State persistence:** all IS state lives in the `mysql-data` volume.
> `docker compose stop` / `up -d` preserves it; only `docker compose down -v`
> wipes it (after which: re-run `provision-is.py`).

## Verifying

```bash
python3 scripts/demo-smoke.py                          # app-tier healthz
IS_BASE_URL=https://localhost:9443 ./scripts/check-is-config.py   # full IS preflight
docker compose ps                                      # all containers + health
```

## Viewing Logs

```bash
docker compose ps
docker compose logs -f orchestrator     # follow one service
docker compose logs --tail=50 wso2is    # IS server log
docker compose logs -f orchestrator hr_agent it_agent hr_server it_server
```

- **MCP servers** log token enforcement on startup (the `expected_aud` they accept).
- **Orchestrator** logs `orchestrator_config_loaded` (IS URL, agent URLs, LLM mode) and `auth_exchange_success` after a successful Pattern C sign-in.

## Networking

Inside `demo-net`, services reach each other (and IS) by name: `orchestrator` →
`hr_agent:8001` / `it_agent:8002` / `hr_server:8000` / `it_server:8004`; all
services → `wso2is:9443`. The browser uses `http://localhost:8090` and
`https://wso2is:9443` (the latter via the `/etc/hosts` entry).

## Troubleshooting

| Problem | Check |
|---------|-------|
| Browser can't reach `https://wso2is:9443` (login redirect / CIBA fails) | Add `127.0.0.1 wso2is` to `/etc/hosts`. |
| IS won't start / DB errors | `docker compose logs wso2is`; ensure `scripts/local-setup.sh` ran (driver + schema present). MySQL must be healthy first. |
| Sign-in "temporarily unavailable" | Run `IS_BASE_URL=https://localhost:9443 ./scripts/check-is-config.py` §4d (agent App-Native auth). If creds are stale, re-run `provision-is.py` against a fresh IS. |
| Fan-out legs `401 invalid_secret` | `INTERNAL_REVOKE_SHARED_SECRET` drifted — `provision-is.py` writes the same value to all five `.env`; re-run `docker compose up -d` so all containers reload it. |
| Token validation / 401s | Confirm `WSO2_IS_BASE_URL=https://wso2is:9443` is reachable from inside the containers and the OAuth apps are subscribed to their API scopes (`check-is-config.py`). |
| LLM not responding | The chat falls back to the keyword router automatically. Check `OPENAI_BASE_URL`/`OPENAI_API_KEY` (AI gateway) in `orchestrator/.env`. |
