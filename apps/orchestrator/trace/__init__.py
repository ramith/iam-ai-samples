"""Under-the-hood HTTP trace surface.

Captures the orchestrator's *outbound* HTTP calls (orchestrator → specialist
agents over A2A, plus the reports/health proxy calls) keyed by ``X-Request-ID``
so the SPA can show — for every chat request — the real request/response/headers
that happened behind the scenes.

Sensitive material (bearer tokens, internal shared secrets, cookies) is masked
before anything leaves the process; raw token bytes are never returned to the
browser.
"""
