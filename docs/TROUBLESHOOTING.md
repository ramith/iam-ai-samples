# Troubleshooting

Symptom → cause → fix. Most issues here were hit during bring-up and are now
prevented by the bootstrap, but they recur if the environment drifts.

## Build fails: `manifest for wso2/wso2is:<version>-alpine not found` / pull error
**Cause:** the configured `WSO2IS_VERSION` has no matching `-alpine` tag on Docker
Hub, or there's no outbound internet to pull the image.
**Fix:** pick a version whose tag exists on
[Docker Hub](https://hub.docker.com/r/wso2/wso2is/tags) (≥ 7.3.0) — either
`WSO2IS_VERSION=7.4.0 ./start.sh` or edit `ARG WSO2IS_VERSION` in
`wso2-is/Dockerfile`. Verify connectivity: `docker pull wso2/wso2is:7.3.0-alpine`.

## WSO2 IS container exits with `Killed` (OOM)
**Cause:** the Docker VM has too little RAM; the IS JVM is OOM-killed (`OOMKilled: true`).
**Fix:** give the VM ≥ 8 GB. Colima: `colima stop && colima start --memory 8 --cpu 4`.
Verify: `docker info | grep "Total Memory"`.

## "Sign in to view reports." even when logged in
**Cause:** stale `orch_sid` cookie — the in-memory session was wiped (e.g. orchestrator
restart) but the browser still sends the old cookie; report calls 401.
**Fix:** hard-refresh (Cmd/Ctrl+Shift+R); the SPA redirects to sign-in after a few
failed SSE reconnects. Then log in again.

## 403 `insufficient_scope` (e.g. requires `hr_read_rest` / `hr_self_rest`)
**Cause:** token-A lacks the role-bound scopes. For **local** users this usually means
the app lost `allowedAudience=ORGANIZATION`. For **federated** users it means
`useMappedLocalSubject` isn't set (local roles not applied). After a clean start the
client IDs change — make sure you **re-logged in** so a fresh token-A is issued.
**Fix:** re-login. If it persists, confirm on `orchestrator-mcp-client`:
`allowedAudience=ORGANIZATION`, `useMappedLocalSubject=true`, `skipLoginConsent=true`
(the bootstrap sets these).

## Reports / sidebar 401 "Invalid audience"
**Cause:** the resource server's REST audience list doesn't include the current
`orchestrator-mcp-client` id (e.g. after a clean start regenerated IDs).
**Fix:** the render script derives `HR_SERVER_REST_VALID_AUDIENCES` /
`IT_SERVER_REST_VALID_AUDIENCES` from `ORCHESTRATOR_MCP_CLIENT_ID`. Re-run
`scripts/render-envs-from-master.sh` (or `./start.sh`) and recreate the servers:
`docker compose up -d hr_server it_server`.

## CIBA consent window shows a **login page** instead of Approve/Deny
**Cause:** the CIBA flow authenticates against the **agent** app, which lacked UAEPass /
a usable authenticator for a federated user.
**Fix:** UAEPass is on the agent apps' login sequence and they use
`useMappedLocalSubject` (bootstrap). Ensure the user has an active IS SSO session.

## CIBA approval returns **401** "authenticated user is not the same as resolved user"
**Cause:** identity mismatch — the federated subject (UAEPass UUID) ≠ the CIBA
`login_hint` (email).
**Fix:** the UAEPass IdP claim mapping uses `email` as the user-id and
`useMappedLocalSubject=true` unifies them (see [UAEPASS.md](UAEPASS.md)). Re-login.

## Agent action returns "could not reach HR/IT Agent" with a validation error
**Cause (historical):** A2A response model rejected an ISO datetime in strict mode.
**Status:** fixed (`ConsentRequiredPayload.prior_consent_at` accepts the string form).
If you see A2A transport errors now, check the agent is `healthy` and reachable.

## Consent no longer appears for repeat actions
**Not a bug:** token-B is cached per `(user, scope)` for its lifetime (UC-06) — by
default **2 min (HR Agent) / 3 min (IT Agent)**, set per app by the bootstrap
(`ensure_agent_oidc_settings`). To demo consent again before it expires:
`docker compose restart hr_agent it_agent` (clears the in-memory token cache).

## UAEPass connector fails to load (OSGi `Could not resolve module … uaepass`)
**Cause:** Nimbus version mismatch (connector wants `< 8`, IS ships `10.3.0`).
**Fix:** the committed JAR is recompiled for Nimbus 10. If you replaced it with the
stock v1.1.6, re-apply the recompile (see [UAEPASS.md](UAEPASS.md)).

## Slow image builds
**Cause:** the ~400 MB IS zip being sent as build context to every service.
**Fix:** already handled — `wso2is` uses context `./wso2-is` and `.dockerignore`
excludes `wso2-is/`. Confirm the Python build context is small
(`du -sh apps libs` ≈ a few MB).

## Edits not taking effect in dev
**Cause:** macOS Colima/VirtioFS file-watch reload misses changes.
**Fix:** `docker compose restart <service>`. For `libs/common` changes, restart the
consuming services. For `requirements.txt`, rebuild:
`docker compose build <svc> && docker compose up -d <svc>`.

## SPA error `Uncaught SyntaxError: Unexpected end of input` (or broken sign-in logo)
**Cause:** after an atomic-write edit, the macOS/Colima bind mount served a *truncated*
copy of a client file (`app.js`/`index.html`) even though the file on disk is complete.
**Fix:** `docker compose restart orchestrator` re-resolves the mount, then hard-refresh
the browser (Cmd/Ctrl+Shift+R). Verify with
`curl -s http://localhost:8090/app.js | wc -l` vs `wc -l apps/client/app.js`.

## Agents panel is empty after a reload/restart
**Cause (fixed):** dev session persistence used to store only token-A, so the issued-token
log (`completed_ciba_log`) was dropped on every `uvicorn --reload` restart.
**Now:** the log and revoked jtis are persisted and flushed on each new token / termination.
If a token was minted *before* this change it won't backfill — run one new agent action.

## `grep-trace.sh` prints "no log lines found" for a valid request id
**Cause (fixed):** the script hard-coded `docker compose` (v2); on a host with only the
v1 `docker-compose` binary every log query errored into `/dev/null`.
**Now:** the script auto-detects v2/v1. If it still finds nothing, the logs may have rotated
(`docker compose logs` keeps a bounded buffer) — reproduce the request and re-run.

## Traces too noisy / missing
- Too noisy (per-request `/events`, `/healthz` spans): set `ENABLE_API_TRACES=0` in the
  service `.env` (default).
- Want the connected orchestrator→hr→it trace: set `ENABLE_API_TRACES=1` on the three
  agent/orchestrator services, then `docker compose up -d orchestrator hr_agent it_agent`.
- `429 Too Many Requests` from the OTEL exporter: the shared AMP key is rate-limited;
  harmless (spans dropped). Use per-service keys to resolve.
