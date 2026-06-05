"""Test-suite conftest.py.

Post-flatten, every service (common/, hr_agent/, it_agent/, hr_server/,
it_server/, orchestrator/) is a real, normally-importable top-level package.

Historically, ~50 test modules hand-roll module loading (importlib
`spec_from_file_location` + `sys.modules` stubbing + bare `_ensure_pkg`
namespace stubs) — a pre-flatten relic from when `common/auth/__init__.py`
couldn't be imported cleanly. In a *joint* pytest run those stubs race on
`sys.modules`: an earlier-collected file registers a fake/namespace module
under a real name, and a later file that imports the real version gets the
stub → `ImportError: ... (unknown location)` / `TypeError`. Each file passes
in isolation; only the joint collection conflicts.

Fix (central, low-risk): pre-import the REAL modules HERE, before any test
module's bootstrap runs. Every per-file `if X not in sys.modules` stub-guard
and `_ensure_pkg` then becomes a no-op, so nothing shadows a real package and
the joint run behaves like the isolated (`tools/run-tests.sh`) run.

This does NOT modify any production source file.
"""

from __future__ import annotations

import importlib

# Pre-import real packages + each service's `main` (which transitively imports
# that service's config, auth/validators, mcp client/tools, ciba.orchestrator,
# a2a.handler, and the shared common.auth.* modules). Wrapped defensively so a
# missing optional dep in a bare CI env degrades to the per-file bootstrap
# rather than erroring out collection.
for _mod in (
    "common.auth",                       # errors, models, jwt_validator, peer_trust, introspector, binding_messages
    "common.a2a.server",
    "common.logging.correlation",
    "common.revocation.jti_denylist",
    "common.revocation.internal_events",
    "hr_agent.main",
    "it_agent.main",
    "hr_server.main",
    "it_server.main",
    "orchestrator.main",
):
    try:
        importlib.import_module(_mod)
    except Exception:  # noqa: BLE001 — degrade to per-file bootstrap if a dep is absent
        pass
