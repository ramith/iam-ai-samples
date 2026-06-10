"""LLM-driven tool routing for the orchestrator chat loop.

``resolve_tool_calls`` is the single entry point ``chat/routes.py`` calls
instead of ``keyword_router.route(...)``:

1. If ``LLM_FALLBACK_MODE != "llm"`` or there's no ``llm_client`` → keyword router.
2. Otherwise: one OpenAI call (function-calling via ``ChatOpenAI.bind_tools()``)
   → read the structured ``tool_calls`` → **validate every returned tool against
   the agent registry** (drop unknown ``agent_id``/``tool_id``; strip
   hallucinated arg keys + non-scalar values; drop the agent-internal
   ``hr.lookup_employee`` if it ever appears) → if any survive, use them;
   else fall back to the keyword router.
3. Any LLM failure (transport/timeout) → keyword router.

The surviving list is ``list[ToolCall]`` — the exact shape ``keyword_router.route``
produces — so the rest of the fan-out in ``chat/routes.py`` is unchanged.

Stdlib + ``orchestrator.llm.client`` + ``orchestrator.chat.keyword_fallback``
(both stdlib-only) — never imports langchain.
"""

from __future__ import annotations

import logging
import re
from typing import TYPE_CHECKING, Any

from traceloop.sdk.decorators import atask  # type: ignore[import-not-found]

from orchestrator.chat.keyword_fallback import ToolCall
from orchestrator.llm.client import ChatHistory, LLMError, RoutedToolCall, ToolCatalogueEntry

if TYPE_CHECKING:  # pragma: no cover
    from orchestrator.chat.routes import ChatRouterDeps

__all__ = ["resolve_tool_calls", "build_catalogue"]

logger = logging.getLogger(__name__)

# Tools the LLM is not allowed to route to even if (mistakenly) carded — these
# are agent-internal helpers, not user-facing chat intents, and their results
# carry data we don't surface (sprint-5.md §2.7). Belt-and-braces; the card
# fixtures already omit them from ``skills[]``.
_INTERNAL_ONLY_TOOLS = frozenset({"hr.lookup_employee"})

_JSON_SCALARS = (str, int, float, bool)
_CUBICLE_ID_RE = re.compile(r"\bC-\d{3}\b", re.IGNORECASE)
_ASSET_ID_RE = re.compile(r"\b[A-Z]{2,4}-[A-Z0-9]+-\d+\b", re.IGNORECASE)
_RECIPIENT_RE = re.compile(r"\b(?:to|for)\s+([A-Za-z][A-Za-z0-9._-]{1,})\b", re.IGNORECASE)
_ONBOARDING_NAME_RE = re.compile(
    r"\b(?:on\s*board|onboard|onboarding)\s+([A-Za-z][A-Za-z0-9._-]{1,})\b",
    re.IGNORECASE,
)
_FLOOR_ONLY_RE = re.compile(r"^\s*(?:floor\s*)?([1-4])\s*$", re.IGNORECASE)
# Matches an email address anywhere in text — used to extract full username like employee@example.com
_EMAIL_RE = re.compile(r"\b[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}\b", re.IGNORECASE)
# Onboarding intent — when present, the IT leg is delegated to hr_agent (which
# calls it_agent over A2A), so the orchestrator should NOT also fan out to
# it_agent directly. Keeps the trace a single chain: orchestrator -> hr -> it.
_ONBOARD_INTENT_RE = re.compile(r"\b(on\s*board|onboard|onboarding)\b", re.IGNORECASE)


def _collapse_onboard_to_hr(
    tool_calls: list[ToolCall], user_message: str
) -> list[ToolCall]:
    """For an onboarding request, drop direct it_agent calls.

    Onboarding delegates the IT kit to hr_agent (hr_agent -> it_agent peer
    call), so a direct orchestrator -> it_agent fan-out would (a) duplicate the
    IT leg and (b) make the trace show two independent agents instead of the
    hr -> it chain. Only collapses when an hr_agent tool is also present, so a
    pure IT request is never silently dropped.
    """
    if not user_message or not _ONBOARD_INTENT_RE.search(user_message):
        return tool_calls
    has_hr = any(tc.agent_id == "hr_agent" for tc in tool_calls)
    if not has_hr:
        return tool_calls
    kept = [tc for tc in tool_calls if tc.agent_id != "it_agent"]
    if len(kept) != len(tool_calls):
        logger.info(
            "onboard_collapsed_it_leg | dropped=%s kept=%s",
            [tc.tool_id for tc in tool_calls if tc.agent_id == "it_agent"],
            [tc.tool_id for tc in kept],
        )
    return kept


def _extract_history_employee(history: ChatHistory | None) -> str | None:
    """Best-effort employee/user token from prior user turns.

    Used to keep guided onboarding flows moving when a follow-up message only
    includes a seat or asset id (e.g. "C-001").
    Prefers a full email address (e.g. employee@example.com) over a bare name.
    """
    if not history:
        return None

    stop = {
        "floor", "seat", "cubicle", "laptop", "phone", "monitor",
        "device", "asset", "equipment", "which", "what", "and", "the", "to", "for",
    }
    for role, text in reversed(history):
        if role != "user" or not text:
            continue
        # Prefer a full email address — it's unambiguous and is the IS username.
        m_email = _EMAIL_RE.search(text)
        if m_email:
            return m_email.group(0)
        m_onboard = _ONBOARDING_NAME_RE.search(text)
        if m_onboard:
            candidate = m_onboard.group(1).strip().rstrip(".,;:!?")
            if candidate.lower() not in stop:
                return candidate
        m_recip = _RECIPIENT_RE.search(text)
        if m_recip:
            candidate = m_recip.group(1).strip().rstrip(".,;:!?")
            if candidate.lower() not in stop:
                return candidate
    return None


def _last_assistant_prompt(history: ChatHistory | None) -> str:
    if not history:
        return ""
    for role, text in reversed(history):
        if role == "assistant" and text:
            return text.lower()
    return ""


def _recent_history_text(history: ChatHistory | None, *, turns: int = 12) -> str:
    """Return a lowercase joined view of recent turns for cue detection."""
    if not history:
        return ""
    tail = history[-turns:] if len(history) > turns else history
    return "\n".join((text or "").lower() for _, text in tail)


def _enrich_tool_calls(
    tool_calls: list[ToolCall],
    user_message: str,
    history: ChatHistory | None,
) -> list[ToolCall]:
    """Fill missing guided-flow args from the current turn + prior chat."""
    if not tool_calls:
        return tool_calls

    employee_hint = _extract_history_employee(history)
    recip_now = _RECIPIENT_RE.search(user_message)
    recip_now_text = recip_now.group(1).strip().rstrip(".,;:!?") if recip_now else None
    cubicle_now = _CUBICLE_ID_RE.search(user_message)
    asset_now = _ASSET_ID_RE.search(user_message)
    floor_now = _FLOOR_ONLY_RE.match(user_message.strip())

    enriched: list[ToolCall] = []
    for tc in tool_calls:
        args = dict(tc.args or {})
        if tc.tool_id == "hr.cubicle_list_floor" and "floor" not in args and floor_now:
            args["floor"] = int(floor_now.group(1))
        elif tc.tool_id == "hr.cubicle_assign":
            if "cubicle_id" not in args and cubicle_now:
                args["cubicle_id"] = cubicle_now.group(0).upper()
            if "employee_username" not in args:
                if recip_now_text:
                    args["employee_username"] = recip_now_text
                elif employee_hint:
                    args["employee_username"] = employee_hint
        elif tc.tool_id == "it.issue_asset":
            if "asset_id" not in args and asset_now:
                args["asset_id"] = asset_now.group(0).upper()
            if "employee_id" not in args:
                if recip_now_text:
                    args["employee_id"] = recip_now_text
                elif employee_hint:
                    args["employee_id"] = employee_hint
        enriched.append(ToolCall(agent_id=tc.agent_id, tool_id=tc.tool_id, args=args))
    return enriched


def _infer_follow_up_tool_calls(
    user_message: str,
    history: ChatHistory | None,
) -> list[ToolCall]:
    """Infer tool calls for terse guided-flow replies in keyword mode."""
    if not history:
        return []

    prompt = _last_assistant_prompt(history)
    recent = _recent_history_text(history)
    msg = user_message.strip()
    if not msg:
        return []

    floor_only = _FLOOR_ONLY_RE.match(msg)
    if floor_only and "which floor would you like to allocate on" in prompt:
        return [
            ToolCall(
                agent_id="hr_agent",
                tool_id="hr.cubicle_list_floor",
                args={"floor": int(floor_only.group(1))},
            )
        ]

    cubicle = _CUBICLE_ID_RE.search(msg)
    if cubicle and "which seat would you like" in prompt:
        args = {"cubicle_id": cubicle.group(0).upper()}
        employee_hint = _extract_history_employee(history)
        if employee_hint:
            args["employee_username"] = employee_hint
        return [ToolCall(agent_id="hr_agent", tool_id="hr.cubicle_assign", args=args)]

    asset = _ASSET_ID_RE.search(msg)
    device_context = (
        "available equipment" in prompt
        or "which one" in prompt and "issue" in prompt
        or "available equipment" in recent
        or "laptop" in recent
        or "phone" in recent
        or "monitor" in recent
        or "on board" in recent
        or "onboard" in recent
        or "onboarding" in recent
    )
    if asset and device_context:
        args = {"asset_id": asset.group(0).upper()}
        employee_hint = _extract_history_employee(history)
        if employee_hint:
            args["employee_id"] = employee_hint
        return [ToolCall(agent_id="it_agent", tool_id="it.issue_asset", args=args)]

    return []


def build_catalogue(agent_registry: Any) -> list[ToolCatalogueEntry]:
    """Build the tool catalogue from ``AgentRegistry.llm_tool_list()``."""
    out: list[ToolCatalogueEntry] = []
    for entry in agent_registry.llm_tool_list():
        out.append(
            ToolCatalogueEntry(
                agent_id=str(entry.get("agent_id", "")),
                tool_id=str(entry.get("tool_id", "")),
                label=str(entry.get("label", entry.get("tool_id", ""))),
                description=str(entry.get("description", "")),
                args=tuple(str(a) for a in (entry.get("args") or ())),
            )
        )
    return out


def _validate(routed: list[RoutedToolCall], deps: "ChatRouterDeps") -> list[ToolCall]:
    """Drop anything not in the registry; filter hallucinated args."""
    out: list[ToolCall] = []
    registry = deps.agent_registry
    a2a_clients = deps.a2a_clients
    for rc in routed:
        if rc.tool_id in _INTERNAL_ONLY_TOOLS:
            logger.warning("llm_router_dropped_internal_tool tool=%s", rc.tool_id)
            continue
        if rc.agent_id not in a2a_clients:
            logger.warning(
                "llm_router_dropped_unknown_agent agent=%s tool=%s", rc.agent_id, rc.tool_id
            )
            continue
        card = registry.get(rc.agent_id)
        if card is None:
            logger.warning(
                "llm_router_dropped_unknown_agent agent=%s tool=%s", rc.agent_id, rc.tool_id
            )
            continue
        skill = next((s for s in getattr(card, "skills", []) if getattr(s, "tool_id", None) == rc.tool_id), None)
        if skill is None:
            logger.warning(
                "llm_router_dropped_unknown_tool agent=%s tool=%s", rc.agent_id, rc.tool_id
            )
            continue
        # Allowed arg names for this skill (the card is the contract).
        allowed: set[str] = set(getattr(skill, "args", []) or [])
        filtered = {
            k: v
            for k, v in (rc.args or {}).items()
            if k in allowed and isinstance(v, _JSON_SCALARS)
        }
        out.append(ToolCall(agent_id=rc.agent_id, tool_id=rc.tool_id, args=filtered))
    return out


@atask(name="llm_router")
async def resolve_tool_calls(
    user_message: str,
    deps: "ChatRouterDeps",
    *,
    history: ChatHistory | None = None,
) -> list[ToolCall]:
    """Resolve the user's message to an ordered list of ``ToolCall``s.

    LLM-primary when configured (the prior chat turns in *history* are replayed
    into the router prompt so follow-ups like "it will be a sick leave" resolve
    correctly); the keyword router is the fallback for an LLM failure, an
    empty/all-invalid LLM response, or keyword-mode deployments. The keyword
    router is single-shot and ignores history (acceptable — it's the fallback).
    """
    use_llm = getattr(deps.config, "llm_fallback_mode", "keyword") == "llm" and deps.llm_client is not None
    if use_llm:
        try:
            catalogue = build_catalogue(deps.agent_registry)
            routed = await deps.llm_client.route(  # type: ignore[union-attr]
                user_message, catalogue, history=history
            )
            tool_calls = _enrich_tool_calls(_validate(routed, deps), user_message, history)
            if tool_calls:
                logger.info("llm_router_ok tools=%s", [tc.tool_id for tc in tool_calls])
                return tool_calls
            logger.info("llm_router_empty_or_all_invalid falling_back_to_keyword")
        except (LLMError, Exception) as exc:  # noqa: BLE001 — any LLM-path failure → keyword fallback
            logger.warning("llm_router_failed reason=%s falling_back_to_keyword", exc)
    keyword_calls = _enrich_tool_calls(deps.keyword_router.route(user_message), user_message, history)
    if keyword_calls:
        return keyword_calls
    return _infer_follow_up_tool_calls(user_message, history)
