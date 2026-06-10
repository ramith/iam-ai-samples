"""HR-agent -> IT-agent peer coordination client (non-CIBA).

Used during onboarding: after assigning a new hire's cubicle, hr_agent asks
it_agent for the standard new-hire IT kit so the reply can tell the admin what
to issue. This is a coordination/read call only — it returns static policy data
and never issues an asset (that stays on the orchestrator -> it_agent CIBA path).

Best-effort by design: any failure returns ``None`` and the caller proceeds
without the kit hint, so the cubicle assignment is never blocked by IT-agent
availability.
"""

from __future__ import annotations

import logging

import httpx

try:  # OTEL is present via amp-instrument; degrade gracefully if not.
    from opentelemetry import propagate, trace
    from opentelemetry.trace import SpanKind
    _TRACER = trace.get_tracer("hr_agent.peer")
except Exception:  # noqa: BLE001
    propagate = None  # type: ignore[assignment]
    _TRACER = None  # type: ignore[assignment]
    SpanKind = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)

__all__ = ["ITPeerClient"]


import contextlib


def _nullcontext():
    return contextlib.nullcontext()


class ITPeerClient:
    """Thin async client for it_agent's ``/a2a/peer/*`` coordination endpoints."""

    def __init__(self, base_url: str, *, agent_label: str = "hr-agent", insecure_tls: bool = False) -> None:
        self._base_url = base_url.rstrip("/")
        self._agent_label = agent_label
        self._verify = not insecure_tls

    async def fetch_onboard_kit(self, *, request_id: str | None = None) -> dict | None:
        """Return it_agent's standard new-hire kit, or ``None`` on any failure."""
        url = f"{self._base_url}/a2a/peer/onboard-kit"
        headers = {"X-Peer-Agent": self._agent_label}
        if request_id:
            headers["X-Request-ID"] = request_id

        # Wrap the call in an explicit CLIENT span and inject W3C trace context
        # so it_agent's auto-instrumented server span nests under hr_agent's
        # trace — makes the hr->it chain visible as one connected trace rather
        # than two independent ones. (httpx is not auto-instrumented here.)
        span_cm = (
            _TRACER.start_as_current_span("it_agent.peer.onboard_kit", kind=SpanKind.CLIENT)
            if _TRACER is not None
            else _nullcontext()
        )
        try:
            with span_cm:
                if propagate is not None:
                    propagate.inject(headers)  # adds traceparent within the span
                async with httpx.AsyncClient(verify=self._verify, timeout=5.0) as client:
                    resp = await client.post(url, headers=headers)
                    resp.raise_for_status()
                    data = resp.json()
                    logger.info(
                        "hr_to_it_peer_onboard_kit_ok request_id=%s items=%d",
                        request_id, len(data.get("kit", [])),
                    )
                    return data
        except Exception as exc:  # noqa: BLE001 — best-effort coordination
            logger.warning(
                "hr_to_it_peer_onboard_kit_failed request_id=%s err=%r url=%s",
                request_id, exc, url,
            )
            return None
