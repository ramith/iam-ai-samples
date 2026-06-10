"""orchestrator/agents/routes.py — Agents panel (fleet status + token termination).

This router powers the SPA "Agents" section, a demo surface that makes the
otherwise-invisible token machinery observable:

    GET  /api/agents                      list agents + health + token status
    POST /api/agents/{agent_id}/revoke    terminate this user's live OBO tokens
                                          for one agent (UC-10 admin-terminate)

Why this exists
---------------
After a CIBA consent the specialist agent caches its on-behalf-of (token-B/OBO)
token for ~1 h (UC-06), so repeat actions don't re-prompt. That cache is
invisible to the user. This panel surfaces, per agent:

  * identity (id, display name, OAuth client id, advertised skills/scopes)
  * liveness (polled ``/healthz``)
  * the live OBO tokens issued *in this session* (from
    ``Session.completed_ciba_log``), each with issued/expiry/status.

The Terminate button calls the SAME revocation fan-out the logout cascade uses
(``InternalEventsClient`` → ``POST /internal/events`` on every service). Each
receiver adds the jti to its denylist and the agent evicts its cached OBO
token — so the *next* action for that agent triggers a fresh CIBA consent.
That is the behaviour the panel demonstrates.

Boundary rules
--------------
- F-09: ``AgentsRouterDeps`` is a ``@dataclass`` (runtime refs: session store,
  registry, events client, http client).
- F-02: the mutating ``/revoke`` endpoint requires ``X-Request-ID`` (CSRF
  guard), mirroring ``/auth/logout`` and the reports actions.
- Read-only fields only: jtis are masked, no token material is ever returned.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from common.logging.correlation import get_request_id
from orchestrator.agent_registry.cards import AgentRegistry
from orchestrator.agent_registry.revoke_client import InternalEventsClient
from orchestrator.auth.session_store import Session, SessionStore

__all__ = ["AgentsRouterDeps", "build_agents_router"]

_logger = logging.getLogger(__name__)


@dataclass
class AgentsRouterDeps:
    """Dependency bundle for the agents router factory.

    Attributes:
        session_store: Cookie → ``Session`` store.
        agent_registry: Loaded specialist ``AgentCard`` registry.
        session_cookie_name: Cookie name to authenticate the caller.
        http_client: Object exposing ``async get(url, headers=...)`` — used to
            poll each agent's ``/healthz``. The lifespan-owned late-binding
            proxy is fine here.
        events_client: Fan-out client (``None`` when the shared secret is
            unset — revoke then degrades to a local-mark-only demo).
        agent_urls: agent_id → base URL (for ``/healthz`` polling).
        orchestrator_label: Display name for the orchestrator's own row.
        orchestrator_client_id: The orchestrator/MCP confidential client id
            (shown on the orchestrator row for context).
    """

    session_store: SessionStore
    agent_registry: AgentRegistry
    session_cookie_name: str
    http_client: object
    events_client: InternalEventsClient | None = None
    agent_urls: dict[str, str] = field(default_factory=dict)
    orchestrator_label: str = "Orchestrator"
    orchestrator_client_id: str = ""


def _mask_jti(jti: str) -> str:
    """Return a display-safe jti (first 8 + last 4), never the full value."""
    if not jti:
        return ""
    if len(jti) <= 14:
        return jti
    return f"{jti[:8]}…{jti[-4:]}"


# Human-readable meaning for each OAuth scope the demo issues. Surfaced in the
# Agents panel so a viewer understands what a given token is actually allowed to
# do. Keep in sync with docs/scope-policy.md and the agent cards.
_SCOPE_MEANINGS: dict[str, str] = {
    "openid": "Sign-in identity (OIDC)",
    "profile": "Basic profile attributes",
    "email": "Email address",
    # HR business scopes
    "hr_basic_rest": "Basic HR access (identity / profile lookups)",
    "hr_self_rest": "Read/act on the caller's own HR data (leave balance, history, apply)",
    "hr_read_rest": "Read aggregate HR reports (pending leaves, cubicles)",
    "hr_approve_rest": "Approve or reject others' leave requests (HR Admin)",
    "hr_assets_write_rest": "Assign / modify HR-side resources (e.g. cubicles)",
    # IT business scopes
    "it_assets_self_rest": "Read the caller's own assigned IT assets",
    "it_assets_read_rest": "Read aggregate IT asset/device assignments",
    "it_assets_write_rest": "Issue / modify IT asset assignments",
    # A2A / CIBA action scopes (namespaced tool scopes)
    "hr.read": "Read HR records on behalf of the user",
    "hr.write": "Modify HR records on behalf of the user",
    "it.read": "Read IT records on behalf of the user",
    "it.write": "Modify IT records on behalf of the user",
}


def _scope_meaning(scope: str) -> str:
    """Best-effort human description for a single scope token."""
    return _SCOPE_MEANINGS.get(scope, "Custom scope")


# The COMPLETE set of OAuth scopes each agent's app is authorized to request,
# mirroring the `ensure_authorized_api` grants in
# scripts/bootstrap-wso2is-entrypoint.sh. Shown in the Agents panel so a viewer
# sees an agent's full capability surface — not just the scopes wired to its
# currently-advertised skills. Keep in sync with the bootstrap.
_AGENT_AUTHORIZED_SCOPES: dict[str, list[str]] = {
    # Orchestrator (BFF): show only the sign-in (OIDC) scopes its login
    # actually needs — not the downstream business scopes. The business
    # scopes are exercised by the specialist agents, shown on their rows.
    "orchestrator": ["openid", "profile", "email"],
    "hr_agent": [
        "hr_basic_rest", "hr_self_rest", "hr_read_rest",
        "hr_approve_rest", "hr_assets_write_rest",
    ],
    "it_agent": [
        "it_assets_read_rest", "it_assets_self_rest", "it_assets_write_rest",
    ],
}


def _authorized_scope_list(agent_id: str, fallback: list[str] | None = None) -> list[dict]:
    """Full authorized scopes for *agent_id* as [{name, meaning}, …]."""
    names = _AGENT_AUTHORIZED_SCOPES.get(agent_id)
    if names is None:
        names = sorted(set(fallback or []))
    return [{"name": n, "meaning": _scope_meaning(n)} for n in names]


def build_agents_router(deps: AgentsRouterDeps) -> APIRouter:
    """Build the agents router with the supplied deps closure."""
    router = APIRouter(tags=["agents"])

    async def _resolve_session(request: Request) -> Session | JSONResponse:
        session_id = request.cookies.get(deps.session_cookie_name)
        unauth = JSONResponse(
            status_code=401,
            content={
                "error_id": "ERR-AUTH-001",
                "message": "Sign in required.",
                "request_id": get_request_id() or "",
            },
        )
        if not session_id:
            return unauth
        try:
            session: Session = await deps.session_store.get_or_404(session_id)
        except KeyError:
            return unauth
        if session.terminating:
            return unauth
        return session

    async def _probe_health(agent_id: str) -> str:
        """Return ``"up"`` / ``"down"`` / ``"unknown"`` for an agent's /healthz."""
        base = deps.agent_urls.get(agent_id)
        if not base:
            return "unknown"
        url = base.rstrip("/") + "/healthz"
        try:
            resp = await deps.http_client.get(url)  # type: ignore[attr-defined]
            return "up" if 200 <= resp.status_code < 300 else "down"
        except Exception as exc:  # noqa: BLE001 — health is best-effort
            _logger.debug("agent_health_probe_failed agent_id=%s err=%r", agent_id, exc)
            return "down"

    def _skill_index(agent_id: str) -> dict[str, dict]:
        """tool_id → {label, description} for one agent's advertised skills."""
        card = deps.agent_registry.get(agent_id)
        if card is None:
            return {}
        out: dict[str, dict] = {}
        for s in card.skills:
            out[s.tool_id] = {
                "label": getattr(s, "label", s.tool_id),
                "description": getattr(s, "description", ""),
            }
        return out

    def _scope_list(scope: str) -> list[dict]:
        """Split a space-separated scope string into [{name, meaning}, …]."""
        seen: set[str] = set()
        out: list[dict] = []
        for tok in (scope or "").split():
            if tok in seen:
                continue
            seen.add(tok)
            out.append({"name": tok, "meaning": _scope_meaning(tok)})
        return out

    def _token_rows(session: Session, agent_id: str, now: int) -> list[dict]:
        """Project this session's issued OBO tokens for *agent_id*.

        Each row carries a stable ``token_id`` (the record's index in the
        append-only ``completed_ciba_log``) so the SPA can request termination
        of one specific token without ever handling the raw jti, plus the
        scopes it carries and the action (purpose) that minted it.
        """
        skills = _skill_index(agent_id)
        rows: list[dict] = []
        for idx, rec in enumerate(session.completed_ciba_log):
            if rec.agent_id != agent_id:
                continue
            if rec.jti in session.revoked_jtis:
                status = "revoked"
            elif rec.exp <= now:
                status = "expired"
            else:
                status = "active"
            skill = skills.get(rec.tool_id, {})
            purpose = skill.get("label") or rec.tool_id or "On-behalf-of action"
            rows.append(
                {
                    "token_id": idx,
                    "jti": _mask_jti(rec.jti),
                    "issued_at": rec.iat,
                    "expires_at": rec.exp,
                    "expires_in": max(0, rec.exp - now),
                    "status": status,
                    "tool_id": rec.tool_id,
                    "purpose": purpose,
                    "purpose_detail": skill.get("description", ""),
                    "scopes": _scope_list(rec.scope),
                }
            )
        # Newest first.
        rows.sort(key=lambda r: r["issued_at"], reverse=True)
        return rows

    # ── GET /api/agents ──────────────────────────────────────────────────────

    @router.get("/api/agents")
    async def list_agents(request: Request) -> JSONResponse:
        """List the agent fleet with liveness and per-agent token status.

        Cookie-authenticated. Returns the orchestrator (BFF confidential
        client) plus every registered specialist. Token rows are derived from
        the caller's own session — they reflect *that user's* live OBO tokens,
        not a global view.
        """
        session_or_err = await _resolve_session(request)
        if isinstance(session_or_err, JSONResponse):
            return session_or_err
        session: Session = session_or_err
        now = int(time.time())

        agents: list[dict] = []

        # Orchestrator row (the confidential BFF client). It holds the user's
        # token-A (the session token), not per-action OBO tokens, so it has no
        # revocable token rows here — terminating it == signing out.
        token_a = session.token_a
        ta_exp = int(token_a.expires_at.timestamp()) if token_a is not None else 0
        agents.append(
            {
                "agent_id": "orchestrator",
                "name": deps.orchestrator_label,
                "kind": "orchestrator",
                "health": "up",  # we are the orchestrator answering this call
                "oauth_client_id": deps.orchestrator_client_id,
                "scopes": _authorized_scope_list("orchestrator"),
                "revocable": False,
                "session_token": {
                    "status": "active" if ta_exp > now else "expired",
                    "expires_at": ta_exp,
                    "expires_in": max(0, ta_exp - now),
                },
                "tokens": [],
                "active_token_count": 0,
            }
        )

        # Specialist rows from the registry.
        for card in deps.agent_registry.all():
            health = await _probe_health(card.id)
            skill_scopes = [s.scope for s in card.skills if getattr(s, "scope", "")]
            scopes = _authorized_scope_list(card.id, fallback=skill_scopes)
            tokens = _token_rows(session, card.id, now)
            active = sum(1 for t in tokens if t["status"] == "active")
            agents.append(
                {
                    "agent_id": card.id,
                    "name": card.label,
                    "kind": "specialist",
                    "health": health,
                    "oauth_client_id": card.oauth_client_id,
                    "scopes": scopes,
                    "revocable": True,
                    "token_validity_seconds": getattr(card, "token_validity_seconds", None),
                    "tokens": tokens,
                    "active_token_count": active,
                }
            )

        return JSONResponse(
            status_code=200,
            content={
                "agents": agents,
                "fanout_enabled": deps.events_client is not None,
                "server_time": now,
                "request_id": get_request_id() or "",
            },
        )

    # ── POST /api/agents/{agent_id}/revoke ────────────────────────────────────

    @router.post("/api/agents/{agent_id}/revoke")
    async def revoke_agent_tokens(agent_id: str, request: Request) -> JSONResponse:
        """Terminate this user's live OBO tokens for *agent_id*.

        Body (optional JSON):
            ``{"token_id": <int>}`` — terminate only that one token (the
            index from ``GET /api/agents``). Omitted → terminate every active
            token for the agent ("Terminate all").

        Flow:
            1. Require ``X-Request-ID`` (F-02 CSRF guard).
            2. Cookie auth → 401 on missing / terminating session.
            3. Reject ``orchestrator`` (not revocable here — use Sign out).
            4. Reject unknown agent ids (404).
            5. For each selected active (non-revoked, non-expired) token, fan
               out a ``session-revoked`` event to all services and mark the
               jti revoked locally so the panel reflects it.
            6. Return ``{ok, agent_id, revoked_count, fanout_enabled}``.
        """
        rid = request.headers.get("X-Request-ID")
        if not rid:
            raise HTTPException(status_code=400, detail="X-Request-ID required")

        # Parse the optional single-token selector. Tolerate an empty body.
        token_id: int | None = None
        try:
            body = await request.json()
            if isinstance(body, dict) and body.get("token_id") is not None:
                token_id = int(body["token_id"])
        except Exception:  # noqa: BLE001 — no/!json body ⇒ terminate-all
            token_id = None

        session_or_err = await _resolve_session(request)
        if isinstance(session_or_err, JSONResponse):
            return session_or_err
        session: Session = session_or_err

        if agent_id == "orchestrator":
            return JSONResponse(
                status_code=400,
                content={
                    "error_id": "ERR-AGENT-not-revocable",
                    "message": "The orchestrator session token is terminated by signing out.",
                    "request_id": rid,
                },
            )
        if deps.agent_registry.get(agent_id) is None:
            return JSONResponse(
                status_code=404,
                content={
                    "error_id": "ERR-AGENT-unknown",
                    "message": f"Unknown agent '{agent_id}'.",
                    "request_id": rid,
                },
            )

        now = int(time.time())
        log = session.completed_ciba_log

        def _is_target(idx: int, rec) -> bool:  # type: ignore[no-untyped-def]
            if rec.agent_id != agent_id:
                return False
            if rec.jti in session.revoked_jtis or rec.exp <= now:
                return False
            return token_id is None or idx == token_id

        targets = [rec for idx, rec in enumerate(log) if _is_target(idx, rec)]

        if token_id is not None and not targets:
            return JSONResponse(
                status_code=404,
                content={
                    "error_id": "ERR-TOKEN-not-found",
                    "message": "No matching active token to terminate.",
                    "request_id": rid,
                },
            )

        revoked = 0
        for rec in targets:
            if deps.events_client is not None:
                try:
                    await deps.events_client.fan_out(
                        jti=rec.jti,
                        user_sub=session.user_sub,
                        exp=float(rec.exp),
                        reason="admin_terminated",
                        request_id=rid,
                    )
                except Exception as exc:  # noqa: BLE001 — best-effort, still mark locally
                    _logger.warning(
                        "agent_token_revoke_fanout_failed | rid=%s agent_id=%s jti=%s err=%r",
                        rid,
                        agent_id,
                        rec.jti[:8],
                        exc,
                    )
            session.revoked_jtis.add(rec.jti)
            revoked += 1

        # Flush so terminations survive a uvicorn --reload restart.
        if revoked:
            deps.session_store.persist()

        _logger.info(
            "agent_tokens_terminated | rid=%s agent_id=%s revoked=%d fanout=%s session_id=%s",
            rid,
            agent_id,
            revoked,
            deps.events_client is not None,
            session.session_id[:8],
        )

        return JSONResponse(
            status_code=200,
            content={
                "ok": True,
                "agent_id": agent_id,
                "revoked_count": revoked,
                "fanout_enabled": deps.events_client is not None,
                "request_id": rid,
            },
        )

    return router
