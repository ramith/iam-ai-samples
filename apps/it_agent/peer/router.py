"""IT-agent peer coordination endpoint (sibling-agent A2A, non-CIBA).

Exposes ``POST /a2a/peer/onboard-kit`` — a *consent-free* call another agent
(e.g. hr_agent during onboarding) can make to ask "what standard IT kit does a
new hire get?". It returns static hardware-policy data only — no user identity,
no it_server access, no CIBA. The interactive, consent-bearing asset *issuance*
still flows through the normal orchestrator -> it_agent CIBA path; this endpoint
never issues anything.

Trust: gated by a simple peer allowlist header (``X-Peer-Agent``) checked against
``trusted_peer_callers``. This is coordination metadata, not a security boundary
for user data (there is no user data here), so a lightweight guard is sufficient.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from fastapi import APIRouter, Header, HTTPException, status
from pydantic import BaseModel

logger = logging.getLogger(__name__)

__all__ = ["PeerRouterDeps", "build_peer_router"]

# Static standard new-hire kit. Mirrors it_server _SEED_HARDWARE_POLICY default
# kit (public data; the pre-login info bot already exposes the policy).
_STANDARD_NEW_HIRE_KIT = [
    {"type": "laptop", "model": "MacBook Pro 14", "catalogue_id": "MBP-14-001"},
    {"type": "phone", "model": "iPhone 15 Pro", "catalogue_id": "PHN-IP15-001"},
    {"type": "monitor", "model": "LG 27UK850", "catalogue_id": "MON-LG-001"},
]


class OnboardKitResult(BaseModel):
    """Response for the onboard-kit coordination call."""

    kit: list[dict]
    note: str


@dataclass
class PeerRouterDeps:
    """Injected deps for the peer router.

    Attributes:
        trusted_peer_callers: Agent IDs/labels allowed to call peer endpoints.
            Empty set = allow all (dev default).
    """

    trusted_peer_callers: frozenset[str] = field(default_factory=frozenset)


def build_peer_router(deps: PeerRouterDeps) -> APIRouter:
    router = APIRouter(prefix="/a2a/peer", tags=["peer"])

    @router.post("/onboard-kit", response_model=OnboardKitResult)
    async def onboard_kit(
        x_peer_agent: str | None = Header(default=None),
    ) -> OnboardKitResult:
        """Return the standard IT kit for a new hire (static, no consent)."""
        if deps.trusted_peer_callers and (x_peer_agent or "") not in deps.trusted_peer_callers:
            logger.warning("peer_onboard_kit_denied caller=%r", x_peer_agent)
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail={"error_id": "ERR-PEER-001", "reason": "caller not trusted"},
            )
        logger.info(
            "peer_onboard_kit_served caller=%s items=%d",
            x_peer_agent or "(any)", len(_STANDARD_NEW_HIRE_KIT),
        )
        return OnboardKitResult(
            kit=list(_STANDARD_NEW_HIRE_KIT),
            note="Standard new-hire allocation. Issue via the IT asset flow (requires your approval).",
        )

    return router
