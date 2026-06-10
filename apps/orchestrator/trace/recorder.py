"""In-memory recorder for outbound HTTP calls, keyed by ``X-Request-ID``.

The recorder is installed as a pair of ``httpx`` *event hooks* on the
orchestrator's outbound clients (the two A2A clients and the reports/health
proxy client). For every request it captures method, URL, headers, and body;
for every response it captures status, headers, body, and wall-clock duration.

Design notes
------------
- **Bounded.** At most :data:`MAX_REQUESTS` request-ids are retained (oldest
  evicted first); each request-id keeps at most :data:`MAX_CALLS_PER_REQUEST`
  calls. Bodies are truncated to :data:`MAX_BODY_CHARS`.
- **Masked.** Authorization bearer tokens, internal shared-secret headers,
  and cookies are redacted before storage — raw token bytes never reach the
  browser. Only a short non-secret prefix of a JWT (the ``alg``/``typ`` header
  segment) is kept so the call is recognisable.
- **F-09 boundary.** Plain class, no Pydantic; holds only stdlib state. Safe to
  construct before the event loop starts.
"""

from __future__ import annotations

import json
import logging
import time
from collections import OrderedDict
from typing import Any

import httpx

__all__ = ["HttpTraceRecorder"]

_logger = logging.getLogger(__name__)

MAX_REQUESTS: int = 60
MAX_CALLS_PER_REQUEST: int = 40
MAX_BODY_CHARS: int = 4000

# Header names whose values must never be returned verbatim.
_SENSITIVE_HEADERS: frozenset[str] = frozenset(
    {
        "authorization",
        "x-internal-auth",
        "cookie",
        "set-cookie",
        "proxy-authorization",
    }
)

# Monotonic start markers keyed by id(request) so we can compute duration in the
# response hook without mutating the httpx.Request object.
# (id() is unique for the lifetime of the in-flight request object.)


def _mask_authorization(value: str) -> str:
    """Redact a bearer token, keeping only the non-secret JWT header prefix."""
    prefix = "Bearer "
    if value.startswith(prefix):
        token = value[len(prefix):]
        head = token[:16]
        return f"Bearer {head}…[redacted, {len(token)} chars]"
    return "[redacted]"


def _mask_headers(headers: httpx.Headers) -> list[list[str]]:
    """Return ``[[name, value], …]`` with sensitive values masked."""
    out: list[list[str]] = []
    for name, value in headers.items():
        lname = name.lower()
        if lname == "authorization":
            out.append([name, _mask_authorization(value)])
        elif lname in _SENSITIVE_HEADERS:
            out.append([name, "[redacted]"])
        else:
            out.append([name, value])
    return out


def _decode_body(raw: bytes | None, content_type: str) -> Any:
    """Best-effort decode of a request/response body for display.

    Returns parsed JSON when the content looks like JSON, otherwise a possibly
    truncated UTF-8 string. ``None`` for empty bodies.
    """
    if not raw:
        return None
    text = raw.decode("utf-8", errors="replace")
    truncated = len(text) > MAX_BODY_CHARS
    if truncated:
        text = text[:MAX_BODY_CHARS]
    if "json" in content_type.lower() and not truncated:
        try:
            return json.loads(text)
        except (ValueError, TypeError):
            pass
    if truncated:
        return text + f"\n…[truncated, {len(raw)} bytes total]"
    return text


class HttpTraceRecorder:
    """Records outbound HTTP calls, grouped by ``X-Request-ID``."""

    def __init__(self) -> None:
        # request_id -> list[call dict]; insertion-ordered, oldest first.
        self._by_rid: "OrderedDict[str, list[dict[str, Any]]]" = OrderedDict()
        # id(request) -> (monotonic_start, wall_start) for duration + ordering.
        self._starts: dict[int, tuple[float, float]] = {}

    # ------------------------------------------------------------------
    # httpx event hooks
    # ------------------------------------------------------------------

    def event_hooks(self) -> dict[str, list]:
        """Return the ``event_hooks=`` mapping for an ``httpx.AsyncClient``."""
        return {"request": [self._on_request], "response": [self._on_response]}

    async def _on_request(self, request: httpx.Request) -> None:
        self._starts[id(request)] = (time.monotonic(), time.time())

    async def _on_response(self, response: httpx.Response) -> None:
        request = response.request
        rid = request.headers.get("X-Request-ID") or "_no_request_id"
        start = self._starts.pop(id(request), None)
        mono_start, wall_start = start if start else (None, time.time())

        # Read bodies (cached by httpx — the caller's later .json()/.text still
        # works). Guard each read; never let tracing break the real call.
        try:
            await response.aread()
            resp_raw = response.content
        except Exception:  # noqa: BLE001
            resp_raw = b""
        try:
            req_raw = request.content
        except Exception:  # noqa: BLE001
            req_raw = b""

        duration_ms = (
            round((time.monotonic() - mono_start) * 1000.0, 1)
            if mono_start is not None
            else None
        )

        call = {
            "ts": wall_start,
            "method": request.method,
            "url": str(request.url),
            "request_headers": _mask_headers(request.headers),
            "request_body": _decode_body(
                req_raw, request.headers.get("content-type", "")
            ),
            "status": response.status_code,
            "reason": response.reason_phrase,
            "response_headers": _mask_headers(response.headers),
            "response_body": _decode_body(
                resp_raw, response.headers.get("content-type", "")
            ),
            "duration_ms": duration_ms,
        }
        self._append(rid, call)

    # ------------------------------------------------------------------
    # storage
    # ------------------------------------------------------------------

    def _append(self, rid: str, call: dict[str, Any]) -> None:
        calls = self._by_rid.get(rid)
        if calls is None:
            calls = []
            self._by_rid[rid] = calls
            # Evict oldest request-ids beyond the cap.
            while len(self._by_rid) > MAX_REQUESTS:
                self._by_rid.popitem(last=False)
        self._by_rid.move_to_end(rid)
        calls.append(call)
        if len(calls) > MAX_CALLS_PER_REQUEST:
            del calls[0]

    # ------------------------------------------------------------------
    # read side (used by the trace router)
    # ------------------------------------------------------------------

    def get(self, rid: str) -> list[dict[str, Any]]:
        """Return the captured calls for ``rid`` (oldest first); ``[]`` if none."""
        return list(self._by_rid.get(rid, []))
