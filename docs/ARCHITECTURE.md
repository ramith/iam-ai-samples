# Architecture

## Components

| Component | Tech | Responsibility |
|---|---|---|
| **WSO2 IS 7.3+** | Java/OSGi | OAuth2/OIDC provider, CIBA grant, federation (UAEPass), roles→scopes, branding. Version set via `ARG WSO2IS_VERSION` in `wso2-is/Dockerfile` (pulls the official `wso2/wso2is:<version>-alpine` image from Docker Hub). |
| **orchestrator** | FastAPI | Serves the SPA; BFF login (Pattern C); chat router + composer; A2A client; SSE to the browser; reports proxy; **agents panel** (fleet status + token termination) and **trace** (under-the-hood HTTP capture). Confidential OAuth client `orchestrator-mcp-client`. |
| **hr_agent / it_agent** | FastAPI | Specialist agents. Receive A2A calls, run **CIBA** to obtain on-behalf-of tokens, call their resource server via **MCP**. Each is its own OAuth client (`hr-agent-oauth` / `it-agent-oauth`) + WSO2 "Agent" identity. |
| **hr_server / it_server** | FastAPI | Resource servers. Expose **MCP tools** (`/mcp/tools/*`) and **REST** (`/api/me/*`, `/api/reports/*`). Enforce the F-04 six-step token validation. In-memory data stores. |
| **client** | static JS | The SPA (`app.js`/`index.html`/`styles.css`), served by the orchestrator at `/`. No tokens in the browser — only the `orch_sid` session cookie. |
| **libs/common** | Python | Shared `a2a/` (JSON-RPC client/server/models), `auth/` (CIBA client, JWT validator, actor-token provider, peer trust), `logging/`, `revocation/`. |

## Request flow (chat → action)

```
1. Browser → orchestrator  POST /api/chat            (session cookie)
2. orchestrator router decides tool calls (keyword or LLM)
3. orchestrator → agent    POST /a2a/message/send     (token-A, Bearer)
4. agent initiates CIBA at IS (login_hint = user, actor_token = agent's I4 token)
5. IS returns auth_req_id + auth_url
6. orchestrator pushes the consent widget to the SPA over SSE
7. user approves at IS (the consent window)
8. agent polls /oauth2/token → receives token-B (sub=user, act.sub=agent, scope=...)
9. agent → resource server POST /mcp/tools/<tool>    (token-B, Bearer)
10. resource server runs F-04 validation, executes, returns the result
11. orchestrator composes the reply, pushes chat_message over SSE
```

## Authentication patterns

### Pattern C — BFF login (token-A)
The browser never sees tokens. The orchestrator (confidential client
`orchestrator-mcp-client`) runs the auth-code + PKCE flow **server-side**:
`/authorize` → IS → `/agent-callback` (orchestrator backend) → code exchange →
**token-A** stored in the server-side session. The browser gets only the `orch_sid`
cookie. See `apps/orchestrator/auth/pattern_c.py`.

token-A carries the user's role-derived scopes (e.g. `hr_read_rest`) and an `act`
claim naming the orchestrator agent. The resource servers' REST endpoints accept
token-A (its `aud` = `orchestrator-mcp-client`, allowed via `*_REST_VALID_AUDIENCES`).

### CIBA — per-action consent (token-B / OBO)
For any agent action, the agent calls IS `/oauth2/ciba` with `login_hint` = the user
and its own **actor token**. IS returns an `auth_url` the SPA opens; the user approves;
the agent polls `/oauth2/token` for **token-B** (on-behalf-of: `sub`=user,
`act.sub`=agent, `aud`=agent, `scope`=the tool's scope). Token-B is cached per
`(user, scope)` until it nears expiry (UC-06). Its lifetime is set **per agent app**
by the bootstrap (`ensure_agent_oidc_settings`): **HR Agent = 120 s, IT Agent = 180 s**
by default (each mirrored in `apps/orchestrator/agent_cards/*.json` as
`token_validity_seconds`, surfaced in the Agents panel). The cache keys off the token's
own `exp`, so changing the lifetime propagates automatically. See
`libs/common/auth/ciba_client.py` and `apps/*/ciba/orchestrator.py`.

### MCP token validation — F-04 (six steps)
Every MCP tool call validates token-B:
1. JWT signature (JWKS)  2. `iss`  3. `exp`  4. `aud` == this server's agent
5. `act.sub` ∈ trusted peer agents (depth-1)  6. required scope ⊆ token scopes
Plus step 7: a JTI **denylist** (revocation). See `apps/*/auth/validators.py`.

## A2A and the hr→it chain

The orchestrator talks to agents over **A2A** (JSON-RPC, two-phase: `message/send`
then long-poll `await`). For **onboarding**, the orchestrator fans out to both HR and
IT agents (each drives its own consent). Additionally, `hr_agent` makes a **peer A2A
call** to `it_agent`'s consent-free `/a2a/peer/onboard-kit` endpoint to fetch the
standard new-hire IT kit — a real hr→it chain that needs no extra consent (static
policy data). See `apps/hr_agent/peer/` and `apps/it_agent/peer/`.

## Identity model

Since S5.12 every OAuth app asserts **email as the OIDC subject**, so a user's `sub`
== their email across token-A, token-B, and federated logins. In-memory stores key on
that email. The shared `JWTClaims.effective_sub` returns the email when present so
store lookups are stable regardless of the issuing app's subject config.

Federated (UAEPass) users carry the UAEPass UUID as their raw subject; the IdP claim
mapping (`email` → user-id) plus `useMappedLocalSubject=true` on the apps resolves
them to the matching local account, so their **local roles drive OAuth scopes** and
the CIBA `login_hint` matches the consent-window user. See [UAEPASS.md](UAEPASS.md).

## Agents panel & audit traces

Two operator-facing surfaces, both served by the orchestrator.

**Agents panel** (`apps/orchestrator/agents/`, `GET /api/agents`,
`POST /api/agents/{agent_id}/revoke`). Cookie-authenticated; the view is *per user* —
token rows are derived from that session's `completed_ciba_log`, not a global view.
Each row carries the agent's authorized scopes (mirrors the bootstrap
`ensure_authorized_api` grants; the orchestrator row shows only its OIDC sign-in scopes)
plus the agent's **default token validity** (`token_validity_seconds` from the card),
and one row per issued OBO token with a stable `token_id` (its index in the log),
**masked jti**, status (`active`/`expired`/`revoked`), issued time, purpose, and scopes.
Active rows show a live expiry countdown; expired/revoked rows show the expiry
timestamp. OBO tokens are logged on both the two-phase CIBA path **and** the
synchronous/cache-hit path (`chat/routes.py`), deduped by jti, so cached-token reuse
appears too. Raw token material is never returned to the browser. **Terminate** walks
the matching records and
fires the revocation cascade: `InternalEventsClient.fan_out` → receiver denylists the
jti (F-04 step 7) and `on_revoke` evicts the agent's OBO cache; the agent additionally
revokes the token at IS via RFC 7009 (`/oauth2/revoke`). The jti is added to
`Session.revoked_jtis`. The orchestrator row is non-revocable (revoking it == sign-out).

**Audit traces / under-the-hood** (`apps/orchestrator/trace/`, `GET /api/trace/{rid}`).
An `HttpTraceRecorder` is installed as `httpx` **event hooks** on the orchestrator's
outbound clients (both A2A clients + the reports/health proxy). For every outbound call
it records method, URL, request/response bodies and headers, status, and duration,
grouped by `X-Request-ID`. Bounded (≤60 request-ids × 40 calls, bodies capped). Sensitive
headers (`Authorization`, `X-Internal-Auth`, `Cookie`) are masked before storage. The SPA
fetches this per request id and renders it under the Trace panel. (This is independent of
the OTEL `ENABLE_API_TRACES` span export, which targets a collector, not the browser.)

**Session persistence.** Dev-mode persistence (`SESSION_PERSIST_PATH`,
`auth/session_store.py`) keeps sessions across `uvicorn --reload` restarts. It persists
token-A **and** `completed_ciba_log` + `revoked_jtis`, so the Agents panel survives a
reload. The store flushes (`SessionStore.persist()`) when the chat route appends an
issued token and when the revoke route adds a jti — not only on session create/delete.

**Client-side reload state.** The **chat transcript** and the **audit-trace timeline**
are built in the browser (the server keeps only a short LLM history and per-rid HTTP
detail), so the SPA mirrors both into `sessionStorage` keyed by session id and
rehydrates them on resume (`hydrateChat` / `hydrateTraces` in `apps/client/app.js`),
clearing them on sign-out. A page reload no longer loses the conversation or traces.
The **Sign out?** dialog also fetches `/api/agents` to show the **Application session**
(BFF client id + live session-expiry countdown).

## Build & image optimization

- **wso2is** uses build context `./wso2-is` (not the repo root), so the ~400 MB
  IS zip stays out of the five Python services' build context. With `.dockerignore`
  excluding `wso2-is/`, `tempz/`, `docs/`, etc., the Python build context is ~2.6 MB.
  Within that context the inputs are grouped: `pack/` (the gitignored zip), `uaepass/`
  (connector JAR/JSP/logo) and `entrypoint/`.
- The IS **Dockerfile is multi-stage**: an `extractor` stage unzips the pack, and the
  runtime stage pulls in only the extracted tree via `COPY --from`, so the ~400 MB zip
  never lands in a shipped layer; build-only `unzip` stays in the extractor.
- Python Dockerfiles copy `requirements.txt` and `pip install` **before** copying
  `libs/common` and app code, so editing code never busts the dependency layer
  (code-change rebuilds ~2 s).
- Env hygiene: `PYTHONDONTWRITEBYTECODE`, `PYTHONUNBUFFERED`, `--no-cache-dir`.
- Boot time is dominated by the WSO2 IS JVM (~40–60 s); the Python services boot in seconds.
