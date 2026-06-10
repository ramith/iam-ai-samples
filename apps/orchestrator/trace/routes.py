"""Trace router — exposes captured outbound HTTP calls to the SPA.

``GET /api/trace/{request_id}`` returns the orchestrator's outbound HTTP calls
(orchestrator → specialist agents, plus proxy/health calls) that were made
while handling the chat request identified by ``request_id``.

Auth: cookie session, same gate as the agents/reports routers. Sensitive
header values are already masked by the recorder; this router never returns
raw token material.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from common.logging.correlation import get_request_id
from orchestrator.auth.session_store import Session, SessionStore
from orchestrator.trace.recorder import HttpTraceRecorder

__all__ = ["TraceRouterDeps", "build_trace_router"]

_logger = logging.getLogger(__name__)


@dataclass
class TraceRouterDeps:
    """Dependencies for the trace router.

    Attributes:
        session_store: Authenticates the caller via the session cookie.
        recorder: The shared :class:`HttpTraceRecorder` capturing outbound calls.
        session_cookie_name: Cookie name used to authenticate the caller.
    """

    session_store: SessionStore
    recorder: HttpTraceRecorder
    session_cookie_name: str


def build_trace_router(deps: TraceRouterDeps) -> APIRouter:
    """Build the trace router with the supplied deps closure."""
    router = APIRouter(tags=["trace"])

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

    @router.get("/api/trace/{request_id}")
    async def get_trace(request_id: str, request: Request) -> JSONResponse:
        """Return the outbound HTTP calls captured for ``request_id``."""
        session = await _resolve_session(request)
        if isinstance(session, JSONResponse):
            return session

        calls = deps.recorder.get(request_id)
        return JSONResponse(
            content={
                "request_id": request_id,
                "calls": calls,
                "count": len(calls),
            }
        )

    return router
