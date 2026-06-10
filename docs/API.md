# HTTP API reference

Every HTTP endpoint in the stack, grouped by service. Routes were taken from the
FastAPI route decorators in `apps/*` and `libs/common/`.

## Conventions

- **Host-reachable vs internal.** Only the **orchestrator** (`http://localhost:8090`)
  and **WSO2 IS** (`https://localhost:9443`) are published to the host. The agents and
  resource servers bind to **loopback** and are reached over the Docker network
  (`hr_agent:8001`, `it_agent:8002`, `hr_server:8000`, `it_server:8004`). Browsers only
  ever talk to the orchestrator.
- **Auth.**
  - Orchestrator browser API: the `orch_sid` **session cookie** (Pattern C); no tokens
    in the browser. The exception is `POST /public/chat`, which is unauthenticated.
  - Agent A2A endpoints: **Bearer token-A** (the user's orchestrator token), validated
    for audience + `act.sub` peer trust.
  - Resource-server MCP/REST endpoints: **Bearer token-B** (OBO) or **token-A** (REST
    reports), validated by the F-04 six-step check (see [ARCHITECTURE.md](ARCHITECTURE.md#mcp-token-validation--f-04-six-steps)).
  - `/internal/events`: the `X-Internal-Auth` shared secret (`INTERNAL_REVOKE_SHARED_SECRET`).
- **Correlation.** Every request carries/echoes `X-Request-ID` (see
  `libs/common/logging/correlation.py`); it keys the in-app Trace panel and
  `scripts/grep-trace.sh`.
- **Errors.** Auth/validation failures return a JSON body with a stable `error_id`
  (e.g. `ERR-AUTH-001`, `ERR-MCP-003`); see `libs/common/auth/errors.py`.

---

## Orchestrator (`http://localhost:8090`)

The only host-facing application surface. Source: `apps/orchestrator/`.

### Auth & session — `apps/orchestrator/auth/routes.py`
| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/auth/login` | none | Start Pattern C login; redirect to IS `/authorize` (PKCE). |
| `GET` | `/agent-callback` | none | IS redirect target; returns an HTML relay page that POSTs the code to `/auth/exchange`. |
| `POST` | `/auth/exchange` | none (code) | Exchange the auth code for token-A; set the `orch_sid` cookie; return `{session_id, user_display_name}`. |
| `POST` | `/auth/logout` | cookie | Revoke token-A at IS, fan out the logout/revocation cascade, delete the session. |

### Chat — `apps/orchestrator/chat/routes.py`
| Method | Path | Auth | Purpose |
|---|---|---|---|
| `POST` | `/api/chat` | cookie | Submit a user message; route (keyword/LLM) and fan out to agents; returns a `ChatAck` immediately, results arrive over SSE. |
| `POST` | `/api/ciba/cancel` | cookie | Cancel a pending CIBA consent flow for this session. |

### Public chat — `apps/orchestrator/chat/public_routes.py` (prefix `/public`)
| Method | Path | Auth | Purpose |
|---|---|---|---|
| `POST` | `/public/chat` | **none** | Stateless LLM reply for unauthenticated/public questions (no tools, no consent). |

### Reports & self-service proxies — `apps/orchestrator/reports/routes.py`
Cookie-gated; scope-checked, then forwarded to the resource servers with token-A.
| Method | Path | Backend | Purpose |
|---|---|---|---|
| `GET` | `/api/me/leaves` | hr_server | The signed-in user's leave balance/history. |
| `GET` | `/api/me/cubicle` | hr_server | The user's cubicle assignment. |
| `GET` | `/api/me/assets` | it_server | The user's issued IT assets. |
| `GET` | `/api/reports/leave-requests` | hr_server | HR Admin: pending leave requests. |
| `GET` | `/api/reports/cubicle-assignments` | hr_server | HR Admin: all cubicle assignments. |
| `GET` | `/api/reports/device-assignments` | it_server | HR Admin: all device assignments. |
| `POST` | `/api/reports/leave-requests/{request_id}/approve` | hr_agent (CIBA) | Approve a leave request (drives CIBA consent). |
| `POST` | `/api/reports/leave-requests/{request_id}/reject` | hr_agent (CIBA) | Reject a leave request (drives CIBA consent). |

### Agents panel — `apps/orchestrator/agents/routes.py`
| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/api/agents` | cookie | Per-user fleet view: liveness, authorized scopes, default token validity (`token_validity_seconds`), and one card per issued OBO token (masked jti, status, issued/expiry, purpose, scopes). The orchestrator row carries `session_token` (token-A status + expiry). |
| `POST` | `/api/agents/{agent_id}/revoke` | cookie | Revoke one or all active OBO tokens for an agent (fires the revocation cascade). |

### Trace — `apps/orchestrator/trace/routes.py`
| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/api/trace/{request_id}` | cookie | The captured outbound HTTP calls for one request id (under-the-hood panel; secrets masked). |

### SSE — `apps/orchestrator/events/sse_router.py`
| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/events/{session_id}` | session | Server-Sent Events stream: chat messages, CIBA consent URLs/state changes, routing steps. |

### SPA & ops — `apps/orchestrator/main.py`
| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | Serve the SPA `index.html`. |
| `GET` | `/app.js`, `/styles.css` | Serve the SPA assets (same-origin with the BFF). |
| `GET` | `/healthz` | Liveness probe. |

---

## HR / IT agents (internal — `hr_agent:8001`, `it_agent:8002`)

A2A is JSON-RPC, two-phase (send then long-poll await). The A2A routes are provided by
the shared router factory `libs/common/a2a/server.py`; `/internal/events` by
`libs/common/revocation/internal_events.py`.

| Method | Path | Service | Auth | Purpose |
|---|---|---|---|---|
| `POST` | `/a2a/message/send` | both | Bearer token-A | Inbound A2A: validate token-A (audience + `act.sub` peer trust), initiate CIBA, return `auth_req_id`. |
| `POST` | `/a2a/await` | both | Bearer token-A | Long-poll for CIBA completion / the tool result. |
| `POST` | `/a2a/cancel` | both | Bearer token-A | Abort an in-flight CIBA flow. |
| `POST` | `/a2a/peer/onboard-kit` | **it_agent only** | `X-Peer-Agent` allowlist | Consent-free peer call: return the standard new-hire IT kit (called by hr_agent during onboarding). Source: `apps/it_agent/peer/router.py`. |
| `POST` | `/internal/events` | both | `X-Internal-Auth` | Revocation receiver: denylist a jti + evict the OBO cache. |
| `GET` | `/healthz` | both | none | Liveness probe. |

The CIBA orchestration that backs `/a2a/message/send` lives in `apps/{hr,it}_agent/ciba/orchestrator.py`;
hr_agent's outbound peer client is in `apps/hr_agent/peer/`.

---

## HR resource server (internal — `hr_server:8000`)

Source: `apps/hr_server/`. MCP tools are mounted under `/mcp/tools`
(`apps/hr_server/mcp/tools.py`); REST under `/api` (`apps/hr_server/rest_api/server.py`).
"Scope" is the OAuth scope the presented token must carry (F-04 step 6).

### MCP tools — `POST /mcp/tools/{tool}` (Bearer token-B)
| Tool | Scope | Purpose |
|---|---|---|
| `get_leave_policy` | `hr_basic_rest` | Company leave policy. |
| `get_leave_balance` | `hr_self_rest` | Caller's leave balance. |
| `get_leave_history` | `hr_self_rest` | Caller's leave history. |
| `apply_leave` | `hr_self_rest` | Submit a leave request for the caller. |
| `approve_leave` | `hr_approve_rest` | Approve a leave request. |
| `reject_leave` | `hr_approve_rest` | Reject a leave request. |
| `get_cubicle_summary` | `hr_read_rest` | Vacant cubicles by floor. |
| `get_vacant_cubicles_on_floor` | `hr_read_rest` | Vacant cubicles on one floor. |
| `get_my_cubicle` | `hr_self_rest` | Caller's cubicle assignment. |
| `assign_cubicle` | `hr_assets_write_rest` | Assign a cubicle to an employee. |
| `lookup_employee` | `hr_read_rest` | Look up an employee by name/email. |
| `get_all_leave_requests` | `hr_approve_rest` | List all leave requests (admin). |

### REST — `apps/hr_server/rest_api/server.py` (Bearer token-A or token-B)
| Method | Path | Scope | Purpose |
|---|---|---|---|
| `GET` | `/api/holidays` | `hr_basic_rest` | Public holidays. |
| `GET` | `/api/leave-policy` | `hr_basic_rest` | Leave policy. |
| `GET` | `/api/leave-balance` | `hr_self_rest` | Caller's balance. |
| `GET` | `/api/me/leaves` | `hr_self_rest` | Caller's leave requests. |
| `GET` | `/api/me/cubicle` | `hr_self_rest` | Caller's cubicle. |
| `GET` | `/api/reports/leave-requests` | `hr_read_rest` | All leave requests (report). |
| `GET` | `/api/reports/cubicle-assignments` | `hr_read_rest` | All cubicle assignments (report). |
| `GET` | `/api/leaves`, `/api/leaves/{id}` | `hr_self_rest` / `hr_read_rest` | List / fetch leave requests. |
| `POST` | `/api/leaves` | `hr_self_rest` | Create a leave request. |
| `POST` | `/api/leaves/{id}/approve`, `/api/leaves/{id}/reject` | `hr_approve_rest` | Approve / reject. |
| `POST` | `/reset` | `hr_approve_rest` | Reset the in-memory demo data. |
| `POST` | `/internal/events` | `X-Internal-Auth` | Revocation receiver (denylist jti). |
| `GET` | `/healthz` | none | Liveness probe. |

---

## IT resource server (internal — `it_server:8004`)

Source: `apps/it_server/`.

### MCP tools — `POST /mcp/tools/{tool}` (Bearer token-B)
| Tool | Scope | Purpose |
|---|---|---|
| `list_available_assets` | `it_assets_read_rest` | Asset catalogue (optionally filtered). |
| `get_my_assets` | `it_assets_self_rest` | Caller's issued assets. |
| `issue_asset` | `it_assets_write_rest` | Issue an asset to an employee. |

### REST — `apps/it_server/rest_api/server.py`
| Method | Path | Scope | Purpose |
|---|---|---|---|
| `GET` | `/api/reports/device-assignments` | `it_assets_read_rest` | All device assignments (report). |
| `GET` | `/api/me/assets` | `it_assets_self_rest` | Caller's IT assets. |
| `GET` | `/health` | none | REST-path liveness probe. |
| `POST` | `/internal/events` | `X-Internal-Auth` | Revocation receiver (denylist jti). |
| `GET` | `/healthz` | none | Liveness probe. |

---

## Scopes ↔ roles

Roles are assigned at WSO2 IS by the bootstrap and drive token scopes:

- **employee** → `hr_basic_rest`, `hr_self_rest`, `it_assets_self_rest`
- **HR Admin** → all of employee's, plus `hr_read_rest`, `hr_approve_rest`,
  `hr_assets_write_rest`, `it_assets_read_rest`, `it_assets_write_rest`

A tool/endpoint returns `403 insufficient_scope` (or the agent's CIBA is denied) when
the caller's role lacks the required scope above.

---

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — request flow, Pattern C, CIBA, F-04 validation, revocation cascade.
- [README.md](../README.md#agents-panel--audit-traces) — the Agents panel and Trace panel that consume these APIs.
