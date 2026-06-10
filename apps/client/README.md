# Browser SPA

Single-page chat UI. No build step, no npm — vanilla HTML + CSS + JS
(`index.html`, `app.js`, `styles.css`).

## How it's served

The SPA is **served by the orchestrator**, not by a standalone web server.
The orchestrator Docker image copies `index.html`, `app.js`, and `styles.css`
into `/app/client_static/` and mounts them at `/` (see
`apps/orchestrator/Dockerfile` and `orchestrator/main.py`). Serving the SPA
same-origin with the BFF avoids cross-origin cookie problems for the
`orch_sid` session cookie.

So there is **no separate client container and no port 3001** — bring up the
stack and open the orchestrator:

```bash
./start.sh
# then open:
open http://localhost:8090
```

All `/auth/*`, `/api/*`, and `/events/*` calls go to the same origin
(`localhost:8090`), which is the orchestrator.

## Editing the SPA

Because the files are baked into the orchestrator image at build time, rebuild
the orchestrator after changing them:

```bash
docker compose build orchestrator
docker compose up -d orchestrator
```

For tight iteration in dev, the committed `docker-compose.override.yml` mounts
`apps/client/` into the orchestrator container, so SPA edits are picked up on a
browser refresh (cache-bust via the `?v=` query string in `index.html`); if a
truncated file is served after an edit, `docker compose restart orchestrator`
re-syncs the bind mount.

## Auth flow (Pattern C)

1. User clicks **Sign in** → SPA redirects to `/auth/login?next=/`.
2. Orchestrator runs PKCE + actor-token exchange with WSO2 IS.
3. IS redirects back to `/agent-callback` → orchestrator POSTs `/auth/exchange`,
   sets the `orch_sid` HttpOnly cookie, and returns
   `{session_id, user_display_name}`.
4. SPA opens the SSE stream at `/events/{session_id}`.

## Dev tips

- First hit to WSO2 IS (`https://localhost:9443`) shows a self-signed cert
  warning. Click **Advanced → Proceed** once per browser session. The
  orchestrator itself runs over plain HTTP (`http://localhost:8090`), so no
  cert warning there.
- Inspect SSE events: DevTools → Network → EventStream tab on the
  `/events/{session_id}` request.
- `localStorage` holds `orch_session_id` and `orch_user_name` for page-reload
  resumption. Clear them (or Sign out) to start fresh.
